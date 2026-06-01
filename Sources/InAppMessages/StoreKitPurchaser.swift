//
//  StoreKitPurchaser.swift
//  Galva
//
//  Wraps the StoreKit 2 `Product.purchase(options:)` flow for offers
//  initiated from an in-app message. The bridge calls this from
//  `requestPurchase`; everything else (transaction observation, receipt
//  validation, entitlement updates) stays in the host app's existing
//  StoreKit pipeline per the SDK design notes.
//
//  Inputs (decoded from the bridge `payload`):
//      • `productId: String`               — App Store SKU
//      • `promotionalOffer:` (optional)    — Galva-server-signed offer:
//            offerId, signature (JWS compact string)
//      • `appAccountToken: UUID`           — SDK-attached attribution token
//
//  Promotional offers are JWS-signed
//  ─────────────────────────────────
//  Apple deprecated the legacy 5-tuple
//  `promotionalOffer(offerID:keyID:nonce:signature:timestamp:)` form (and
//  the iOS 17.4 `Signature`-wrapped variant) in favor of
//  `promotionalOffer(_:compactJWS:)`. Galva commits to the JWS path so the
//  server only needs one signing pipeline. Older OSes that don't have the
//  JWS API surface `Failure.invalidOffer` so the bundle can present an
//  "update iOS to redeem" state instead of attempting a fallback that
//  would silently drop the discount.
//
//  Outputs:
//      • `Outcome.completed(Transaction)`  — verified + completed
//      • `Outcome.pending`                 — Ask to Buy / SCA pending
//      • `Outcome.cancelled`               — user dismissed the sheet
//      • `Outcome.unverified(error)`       — App Store signature failed
//      Or, thrown as `Failure`:
//      • `productUnavailable`              — App Store doesn't sell it
//      • `purchaseNotAllowed`              — device-level restriction
//      • `ineligibleForOffer`              — user can't redeem this offer
//      • `invalidOffer(detail)`            — bad offer-signing inputs
//      • `notAvailableInStorefront`        — wrong region
//      • `networkError(underlying)`        — App Store unreachable
//      • `underlying(error)`               — anything else
//
//  We do NOT call `transaction.finish()` here. The host app's
//  `Transaction.updates` listener (RevenueCat, in-house, etc.) receives
//  the same transaction broadcast and owns the lifecycle. Calling
//  finish() ourselves would race with that listener and could lose
//  receipt-based entitlement state.
//

import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(StoreKit)

@MainActor
struct StoreKitPurchaser {

    /// Optional warm-cache so we can skip the round-trip when the SDK
    /// already pre-fetched this productId during `/sdk/initialize`.
    let prefetcher: StoreKitProductPrefetcher?
    let logger: any GalvaLogger

    // MARK: - Public types

    /// Promotional offer parameters. Galva's backend signs offers as JWS
    /// compact strings (header.payload.signature, base64url-encoded). The
    /// SDK passes the JWS straight through to
    /// `Product.PurchaseOption.promotionalOffer(_:compactJWS:)` — none of
    /// the historical 5-tuple components (keyID, nonce, timestamp) are
    /// surfaced because the JWS already carries them.
    struct PromotionalOffer: Sendable, Hashable {
        let offerId: String
        /// JWS compact serialization of the offer's signed claims.
        let compactJWS: String
    }

    /// What the user / App Store ended up doing. Bundles render different
    /// UI for completed vs. cancelled vs. pending — keep them on the
    /// "success" side of the bridge response so the bundle's
    /// purchase-result switch is uniform.
    enum Outcome: Sendable {
        case completed(verified: Bool, transactionId: UInt64, originalId: UInt64,
                       productId: String, purchaseDate: Date, expirationDate: Date?,
                       appAccountToken: UUID?)
        case pending
        case cancelled
    }

    /// Failure categories the bridge maps onto `BridgeError.Code`. Each
    /// case carries enough context for the bundle's diagnostic logging.
    enum Failure: Error, Sendable {
        case productUnavailable
        case purchaseNotAllowed
        case ineligibleForOffer
        case invalidOffer(detail: String)
        case verificationFailed(detail: String)
        case notAvailableInStorefront
        case networkError(underlying: Error)
        case invalidPayload(detail: String)
        case underlying(Error)
    }

    // MARK: - Entry point

    /// Run the full purchase flow on the main actor. Throws `Failure` on
    /// any non-flow error; returns the user-visible `Outcome` on success
    /// (including cancel and pending, which are normal flow outcomes).
    func purchase(
        productId: String,
        promotionalOffer: PromotionalOffer?,
        appAccountToken: UUID
    ) async throws -> Outcome {
        let product = try await resolveProduct(productId: productId)

        var options: Set<Product.PurchaseOption> = []
        options.insert(.appAccountToken(appAccountToken))

        if let promo = promotionalOffer {
            makePromotionalOptions(promo)
                .forEach {
                    options.insert($0)
                }
        }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(options: options)
        } catch let error as Product.PurchaseError {
            throw mapPurchaseError(error)
        } catch let error as StoreKitError {
            throw mapStoreKitError(error)
        } catch {
            throw Failure.underlying(error)
        }

        return try await mapResult(result, fallbackProductId: productId)
    }

    // MARK: - Product resolution

    private func resolveProduct(productId: String) async throws -> Product {
        // Hot path — the prefetcher has it from /sdk/initialize warmup.
        if let prefetcher,
           let cached = await prefetcher.currentProduct(productId: productId) {
            return cached
        }
        // Cold path — fetch live. Falls into `productUnavailable` when
        // the App Store doesn't return a record for the requested id.
        let products: [Product]
        do {
            products = try await Product.products(for: [productId])
        } catch let error as StoreKitError {
            throw mapStoreKitError(error)
        } catch {
            throw Failure.underlying(error)
        }
        guard let product = products.first(where: { $0.id == productId }) else {
            throw Failure.productUnavailable
        }
        return product
    }

    // MARK: - PurchaseResult mapping

    private func mapResult(
        _ result: Product.PurchaseResult,
        fallbackProductId: String
    ) async throws -> Outcome {
        switch result {
        case .success(let verification):
            switch verification {
            case .verified(let transaction):
                logger.info(.identity, "purchase completed", metadata: [
                    "productId": transaction.productID,
                    "transactionId": String(transaction.id),
                ])
                return .completed(
                    verified: true,
                    transactionId: transaction.id,
                    originalId: transaction.originalID,
                    productId: transaction.productID,
                    purchaseDate: transaction.purchaseDate,
                    expirationDate: transaction.expirationDate,
                    appAccountToken: transaction.appAccountToken
                )
            case .unverified(_, let error):
                logger.warning(.identity, "purchase unverified", error: error)
                throw Failure.verificationFailed(detail: String(describing: error))
            }
        case .userCancelled:
            logger.info(.identity, "purchase cancelled by user")
            return .cancelled
        case .pending:
            // Ask to Buy / SCA / payment pending. The transaction will
            // arrive later via `Transaction.updates` to the host app's
            // observer; no further action from the bridge.
            logger.info(.identity, "purchase pending (Ask to Buy / SCA)")
            return .pending
        @unknown default:
            logger.warning(.identity, "purchase result unknown — treating as failure")
            throw Failure.underlying(StoreKitError.unknown)
        }
    }

    // MARK: - Promotional offer construction

    /// Build the set of `Product.PurchaseOption`s that represent a
    /// JWS-signed promotional offer. `promotionalOffer(_:compactJWS:)`
    /// returns an array because StoreKit unpacks the JWS claims into
    /// multiple internal options (offerID, signed timestamp, signature,
    /// etc.) that the purchase flow expects to find independently.
    ///
    /// Availability: Apple back-deployed this API to iOS 15 / macOS 12
    /// / tvOS 15 / watchOS 8 / visionOS 1 — the SDK's deployment floor —
    /// via `@backDeployed(before: iOS 26.0, …)`. No runtime
    /// `#available` gate is needed; the symbol is safe to call on every
    /// supported OS.
    ///
    /// `throws` is preserved despite being a no-throw body today so a
    /// future malformed-JWS check can land here without re-plumbing
    /// every call site.
    private func makePromotionalOptions(
        _ promo: PromotionalOffer
    ) -> [Product.PurchaseOption] {
        // Explicit type prefix because dot-shorthand resolves against the
        // return type (`[Product.PurchaseOption]`); the static factory
        // lives on the element type, not the array.
        return Product.PurchaseOption.promotionalOffer(
            promo.offerId,
            compactJWS: promo.compactJWS
        )
    }

    // MARK: - Error mapping

    private func mapPurchaseError(_ error: Product.PurchaseError) -> Failure {
        switch error {
        case .productUnavailable:
            return .productUnavailable
        case .purchaseNotAllowed:
            return .purchaseNotAllowed
        case .ineligibleForOffer:
            return .ineligibleForOffer
        case .invalidOfferIdentifier:
            return .invalidOffer(detail: "invalidOfferIdentifier")
        case .invalidOfferPrice:
            return .invalidOffer(detail: "invalidOfferPrice")
        case .invalidOfferSignature:
            return .invalidOffer(detail: "invalidOfferSignature")
        case .missingOfferParameters:
            return .invalidOffer(detail: "missingOfferParameters")
        case .invalidQuantity:
            return .invalidPayload(detail: "invalidQuantity")
        @unknown default:
            return .underlying(error)
        }
    }

    private func mapStoreKitError(_ error: StoreKitError) -> Failure {
        switch error {
        case .userCancelled:
            // Treated as a flow outcome elsewhere; thrown here only if
            // StoreKit raises it as an error (rare — usually returned as
            // PurchaseResult.userCancelled). Surface as a no-op cancel.
            return .underlying(error)
        case .networkError(let underlying):
            return .networkError(underlying: underlying)
        case .systemError(let underlying):
            return .underlying(underlying)
        case .notAvailableInStorefront:
            return .notAvailableInStorefront
        case .notEntitled:
            // The user isn't entitled to perform this action — surface as
            // purchaseNotAllowed so the bundle hides the offer surface
            // rather than retry.
            return .purchaseNotAllowed
        case .unsupported:
            // Reported when StoreKit isn't available in the current
            // environment (e.g. macOS Catalyst without entitlements).
            return .underlying(error)
        case .unknown:
            return .underlying(error)
        @unknown default:
            return .underlying(error)
        }
    }
}

#endif // canImport(StoreKit)
