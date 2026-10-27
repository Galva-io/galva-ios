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
//  server only needs one signing pipeline. Apple back-deployed that API to
//  the SDK's floor (iOS 15 / macOS 12), so there's no OS check and no
//  fallback that could silently drop the discount. An offer the backend
//  couldn't sign (no In-App Purchase key in Galva) fails as `invalidOffer`
//  before StoreKit is asked, for the same reason.
//
//  Outputs:
//      • `Outcome.completed(…)`            — verified + completed
//      • `Outcome.pending`                 — Ask to Buy / SCA pending
//      • `Outcome.cancelled`               — user dismissed the sheet or sign-in
//      Or, thrown as `Failure`:
//      • `productUnavailable`              — App Store doesn't sell it
//      • `purchaseNotAllowed`              — device-level restriction
//      • `ineligibleForOffer`              — user can't redeem this offer
//      • `invalidOffer(detail)`            — bad offer-signing inputs
//      • `verificationFailed(detail)`      — App Store signature failed
//      • `notAvailableInStorefront`        — wrong region
//      • `invalidPayload(detail)`          — malformed purchase request
//      • `networkError(underlying)`        — App Store unreachable
//      • `underlying(error)`               — anything else
//
//  We do NOT call `transaction.finish()` here — the host app's billing
//  pipeline (RevenueCat, in-house, etc.) owns the lifecycle, and finishing
//  before it has recorded the transaction could lose entitlement state.
//  Note StoreKit does NOT broadcast a `Product.purchase(options:)`
//  transaction on `Transaction.updates`; the host's listener only receives
//  it, as unfinished, on the next launch. Hosts that need it in-session
//  install a `GalvaPurchaseController` (see `Galva+Purchases.swift`), which
//  reaches this flow through `performPurchase(...)`.
//

import Foundation
import StoreKit

@MainActor
struct StoreKitPurchaser {

    /// Optional warm-cache so we can skip the round-trip when the SDK
    /// already pre-fetched this productId during `/sdk/initialize`.
    let prefetcher: StoreKitProductPrefetcher?
    let logger: any GalvaLogger

    // MARK: - Types

    /// Promotional offer parameters. Galva's backend signs offers as JWS
    /// compact strings (header.payload.signature, base64url-encoded). The
    /// SDK passes the JWS straight through to
    /// `Product.PurchaseOption.promotionalOffer(_:compactJWS:)` — none of
    /// the historical 5-tuple components (keyID, nonce, timestamp) are
    /// surfaced because the JWS already carries them. Public as
    /// `Galva.PromotionalOffer` so purchase controllers receive it too.
    typealias PromotionalOffer = Galva.PromotionalOffer

    /// What the user / App Store ended up doing. Bundles render different
    /// UI for completed vs. cancelled vs. pending — keep them on the
    /// "success" side of the bridge response so the bundle's
    /// purchase-result switch is uniform.
    enum Outcome: Sendable {
        case completed(transactionId: UInt64, originalId: UInt64,
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
        let result = try await performPurchase(
            productId: productId,
            promotionalOffer: promotionalOffer,
            appAccountToken: appAccountToken
        )
        return try await mapResult(result, fallbackProductId: productId)
    }

    /// Resolve the product and drive `Product.purchase(options:)` with the
    /// attribution token and optional JWS offer attached. Returns StoreKit's
    /// raw result with the transaction unfinished. Shared by `purchase(...)`
    /// and `Galva.PurchaseRequest.purchaseWithStoreKit()`.
    func performPurchase(
        productId: String,
        promotionalOffer: PromotionalOffer?,
        appAccountToken: UUID
    ) async throws -> Product.PurchaseResult {
        var options: Set<Product.PurchaseOption> = []
        options.insert(.appAccountToken(appAccountToken))

        if let promo = promotionalOffer {
            guard let compactJWS = promo.compactJWS else {
                logger.warning(.purchases, "promotional offer is unsigned: Galva has no In-App Purchase key for this app. Add one in Galva to sell it with StoreKit, or install a purchase controller that has it signed.", metadata: [
                    "productId": productId,
                    "offerId": promo.offerId,
                ])
                throw Failure.invalidOffer(detail: "unsigned: Galva has no In-App Purchase key for this app")
            }
            makePromotionalOptions(offerId: promo.offerId, compactJWS: compactJWS)
                .forEach {
                    options.insert($0)
                }
        }

        let product = try await resolveProduct(productId: productId)

        return try await Self.settle {
            try await product.purchase(options: options)
        }
    }

    /// Await StoreKit's purchase call, mapping what it throws onto
    /// `Failure`. Static so the mapping is testable without a `Product`.
    static func settle(
        _ purchase: () async throws -> Product.PurchaseResult
    ) async throws -> Product.PurchaseResult {
        do {
            return try await purchase()
        } catch StoreKitError.userCancelled {
            // Thrown rather than returned when the user cancels the Apple ID
            // sign-in StoreKit asks for. Still a cancel, not a failure.
            return .userCancelled
        } catch let error as Product.PurchaseError {
            throw mapPurchaseError(error)
        } catch let error as StoreKitError {
            throw mapStoreKitError(error)
        } catch {
            throw Failure.underlying(error)
        }
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
            throw Self.mapStoreKitError(error)
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
                logger.info(.purchases, "purchase completed", metadata: [
                    "productId": transaction.productID,
                    "transactionId": String(transaction.id),
                ])
                return .verified(transaction)
            case .unverified(_, let error):
                logger.warning(.purchases, "purchase unverified", error: error)
                throw Failure.verificationFailed(detail: String(describing: error))
            }
        case .userCancelled:
            logger.info(.purchases, "purchase cancelled by user")
            return .cancelled
        case .pending:
            // Ask to Buy / SCA / payment pending. The transaction will
            // arrive later via `Transaction.updates` to the host app's
            // observer; no further action from the bridge.
            logger.info(.purchases, "purchase pending (Ask to Buy / SCA)")
            return .pending
        @unknown default:
            logger.warning(.purchases, "purchase result unknown — treating as failure")
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
    /// Availability: Apple back-deployed this API to iOS 15 / macOS 12 —
    /// the SDK's deployment floor — via `@backDeployed(before: iOS 26.0, …)`.
    /// No runtime `#available` gate is needed; the symbol is safe to call
    /// on every supported OS.
    private func makePromotionalOptions(
        offerId: String,
        compactJWS: String
    ) -> [Product.PurchaseOption] {
        // Explicit type prefix because dot-shorthand resolves against the
        // return type (`[Product.PurchaseOption]`); the static factory
        // lives on the element type, not the array.
        return Product.PurchaseOption.promotionalOffer(
            offerId,
            compactJWS: compactJWS
        )
    }

    // MARK: - Error mapping

    private static func mapPurchaseError(_ error: Product.PurchaseError) -> Failure {
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
        #if compiler(>=6.3.2)
        case .paymentMethodBindingConfigurationRequired:
            // Added with billing plans in the iOS 26.5 SDK (Xcode 26.5).
            // Nothing offer-specific to report — a generic purchase failure.
            // Gated so Xcode 26.0–26.4 still compile.
            return .underlying(error)
        #endif
        @unknown default:
            return .underlying(error)
        }
    }

    private static func mapStoreKitError(_ error: StoreKitError) -> Failure {
        switch error {
        case .userCancelled:
            // From the purchase itself `settle` returns it as
            // `.userCancelled`; only a product lookup lands here.
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
        #if compiler(>=6.4)
        case .invalidPresentationContext:
            // Added in the iOS 27 SDK (Xcode 27): StoreKit had no valid
            // context to present the purchase sheet in. Gated so Xcode 26
            // still compiles.
            return .underlying(error)
        #endif
        @unknown default:
            return .underlying(error)
        }
    }
}

// MARK: - Purchase controller interop

extension StoreKitPurchaser.Outcome {

    /// `.completed` for a verified transaction — shared by the built-in flow
    /// and by results a `GalvaPurchaseController` reports.
    static func verified(_ transaction: Transaction) -> Self {
        .completed(
            transactionId: transaction.id,
            originalId: transaction.originalID,
            productId: transaction.productID,
            purchaseDate: transaction.purchaseDate,
            expirationDate: transaction.expirationDate,
            appAccountToken: transaction.appAccountToken
        )
    }

    /// Outcome for a controller-reported result. Controllers hand back
    /// verified transactions only (see `Galva.PurchaseResult.completed`).
    init(_ result: Galva.PurchaseResult) {
        switch result {
        case .completed(let transaction): self = .verified(transaction)
        case .pending:                    self = .pending
        case .cancelled:                  self = .cancelled
        }
    }
}

extension StoreKitPurchaser.Failure {

    /// Public form thrown from `Galva.PurchaseRequest.purchaseWithStoreKit()`.
    var publicError: Galva.PurchaseError {
        switch self {
        case .productUnavailable:             return .productUnavailable
        case .purchaseNotAllowed:             return .purchaseNotAllowed
        case .ineligibleForOffer:             return .ineligibleForOffer
        case .notAvailableInStorefront:       return .notAvailableInStorefront
        case .invalidOffer(let detail):       return .invalidOffer(detail)
        case .verificationFailed(let detail): return .verificationFailed(detail)
        case .networkError(let underlying):   return .networkError(String(describing: underlying))
        case .invalidPayload(let detail):     return .failed(detail)
        case .underlying(let error):          return .failed(String(describing: error))
        }
    }
}
