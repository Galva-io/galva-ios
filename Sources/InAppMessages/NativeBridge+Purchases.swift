//
//  NativeBridge+Purchases.swift
//  Galva
//
//  StoreKit purchase handling for the native bridge.
//
//  Surface:
//    • `handleRequestPurchase(payload:activeMessageId:)` — entry point
//       dispatched from `NativeBridge.handle(envelope:)` for the
//       `.requestPurchase` method.
//
//  Everything else in this file is private: payload parsing
//  (`ParsedPurchaseRequest`, `parsePurchaseRequest`,
//  `parsePromotionalOffer`) and StoreKit outcome / failure encoding
//  (`encodeOutcome`, `mapFailure`). Add a new purchase-related helper
//  here rather than touching the core bridge file.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(WebKit) && canImport(UIKit)

extension NativeBridge {

    /// Drive `Product.purchase(options:)` for the active in-app message.
    ///
    /// Wire payload:
    ///     {
    ///       "productId": "com.app.pro.year",
    ///       "promotionalOffer": {              // optional
    ///         "offerId":   "...",
    ///         "signature": "<JWS compact string>"  // header.payload.signature
    ///       }
    ///     }
    ///
    /// `signature` is the JWS compact serialization Galva's backend signs;
    /// it carries every claim (keyId, nonce, productId, timestamp) the
    /// App Store needs to validate. We deliberately don't accept the
    /// legacy 5-tuple shape any longer — `promotionalOffer(_:compactJWS:)`
    /// is the only API the SDK calls.
    ///
    /// Success response (`result` payload):
    ///     • completed → `{ outcome: "completed", transaction: {…} }`
    ///     • pending   → `{ outcome: "pending" }`
    ///     • cancelled → `{ outcome: "cancelled" }`
    ///
    /// Failure response (`error` payload) uses the structured
    /// `BridgeError.Code` cases (`productUnavailable`,
    /// `purchaseNotAllowed`, `ineligibleForOffer`, `invalidOffer`,
    /// `verificationFailed`, `networkError`, `purchaseFailed` catch-all).
    func handleRequestPurchase(
        payload: [String: AnyJSONValue]?,
        activeMessageId: String
    ) async -> Result<AnyJSONValue?, BridgeError> {
        // 1. Parse payload — productId is required, promotionalOffer is
        //    optional but must be well-formed when present.
        let parsed: ParsedPurchaseRequest
        switch parsePurchaseRequest(payload) {
        case .success(let req): parsed = req
        case .failure(let err): return .failure(err)
        }

        #if canImport(StoreKit)
        // 2. Snapshot the SDK's attribution token across the actor hop.
        let appAccountToken = await identity.purchaseAttributionToken

        logger.info(.identity, "bridge requestPurchase", metadata: [
            "productId": parsed.productId,
            "messageId": activeMessageId,
            "promo": parsed.promotionalOffer == nil ? "false" : "true",
        ])

        // 3. Hand off to the typed StoreKit wrapper. Throws on real
        //    failures; flow outcomes (cancelled / pending) come back as
        //    success results.
        let purchaser = StoreKitPurchaser(
            prefetcher: storeKitPrefetcher,
            logger: logger
        )
        do {
            let outcome = try await purchaser.purchase(
                productId: parsed.productId,
                promotionalOffer: parsed.promotionalOffer,
                appAccountToken: appAccountToken
            )
            return .success(.object(Self.encodeOutcome(outcome)))
        } catch let failure as StoreKitPurchaser.Failure {
            return .failure(Self.mapFailure(failure))
        } catch {
            return .failure(BridgeError(
                code: .purchaseFailed,
                message: String(describing: error)
            ))
        }
        #else
        // Non-Apple platform — StoreKit isn't available; surface a
        // structured failure so the bundle UX degrades gracefully.
        return .failure(BridgeError(
            code: .purchaseFailed,
            message: "StoreKit unavailable on this platform"
        ))
        #endif
    }

    // MARK: - Purchase payload parsing

    private struct ParsedPurchaseRequest {
        let productId: String
        #if canImport(StoreKit)
        let promotionalOffer: StoreKitPurchaser.PromotionalOffer?
        #else
        let promotionalOffer: Void?
        #endif
    }

    private func parsePurchaseRequest(
        _ payload: [String: AnyJSONValue]?
    ) -> Result<ParsedPurchaseRequest, BridgeError> {
        guard let payload,
              case .string(let productId)? = payload["productId"],
              !productId.isEmpty else {
            return .failure(BridgeError(
                code: .invalidPayload,
                message: "Missing productId"
            ))
        }

        #if canImport(StoreKit)
        // promotionalOffer is optional — absent or null both mean "no
        // offer, standard list-price purchase". When present, every
        // field is required; partial offers are rejected so we never
        // hand StoreKit a half-built offer.
        let promo: StoreKitPurchaser.PromotionalOffer?
        if case .object(let promoObj)? = payload["promotionalOffer"] {
            switch parsePromotionalOffer(promoObj) {
            case .success(let p): promo = p
            case .failure(let err): return .failure(err)
            }
        } else if case .null? = payload["promotionalOffer"] {
            promo = nil
        } else if payload["promotionalOffer"] == nil {
            promo = nil
        } else {
            return .failure(BridgeError(
                code: .invalidPayload,
                message: "promotionalOffer must be an object"
            ))
        }
        return .success(.init(productId: productId, promotionalOffer: promo))
        #else
        return .success(.init(productId: productId, promotionalOffer: nil))
        #endif
    }

    #if canImport(StoreKit)
    /// Parse the JWS-only promotional offer payload. Both `offerId` and
    /// `signature` (a JWS compact string) are required — we never quietly
    /// drop a partial offer since the bundle's UX promised the user a
    /// discount and a list-price fallback would surprise them.
    private func parsePromotionalOffer(
        _ obj: [String: AnyJSONValue]
    ) -> Result<StoreKitPurchaser.PromotionalOffer, BridgeError> {
        func string(_ key: String) -> String? {
            if case .string(let s)? = obj[key], !s.isEmpty { return s } else { return nil }
        }
        guard let offerId = string("offerId") else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "promotionalOffer.offerId missing"))
        }
        // Accept either `signature` (the canonical wire name) or
        // `compactJWS` (mirrors Apple's API parameter) so backend / bundle
        // teams can use whichever feels more natural without an SDK bump.
        guard let jws = string("signature") ?? string("compactJWS") else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "promotionalOffer.signature missing (JWS compact string)"))
        }

        return .success(.init(offerId: offerId, compactJWS: jws))
    }

    // MARK: - StoreKit outcome / failure encoding

    private static func encodeOutcome(
        _ outcome: StoreKitPurchaser.Outcome
    ) -> [String: AnyJSONValue] {
        switch outcome {
        case .pending:
            return ["outcome": .string("pending")]
        case .cancelled:
            return ["outcome": .string("cancelled")]
        case .completed(let verified, let transactionId, let originalId,
                        let productId, let purchaseDate, let expirationDate,
                        let appAccountToken):
            var transaction: [String: AnyJSONValue] = [
                "id":                  .string(String(transactionId)),
                "originalId":          .string(String(originalId)),
                "productId":           .string(productId),
                "purchaseDate":        .string(ISO8601DateFormatter.galva.string(from: purchaseDate)),
                "verified":            .bool(verified),
            ]
            if let exp = expirationDate {
                transaction["expirationDate"] = .string(ISO8601DateFormatter.galva.string(from: exp))
            }
            if let tok = appAccountToken {
                transaction["appAccountToken"] = .string(tok.uuidString.lowercased())
            }
            return [
                "outcome": .string("completed"),
                "transaction": .object(transaction),
            ]
        }
    }

    private static func mapFailure(
        _ failure: StoreKitPurchaser.Failure
    ) -> BridgeError {
        switch failure {
        case .productUnavailable:
            return BridgeError(code: .productUnavailable,
                               message: "App Store doesn't recognize this productId")
        case .purchaseNotAllowed:
            return BridgeError(code: .purchaseNotAllowed,
                               message: "Purchases not allowed on this device")
        case .ineligibleForOffer:
            return BridgeError(code: .ineligibleForOffer,
                               message: "User is not eligible for this offer")
        case .invalidOffer(let detail):
            return BridgeError(code: .invalidOffer,
                               message: "Promotional offer rejected by StoreKit: \(detail)")
        case .verificationFailed(let detail):
            return BridgeError(code: .verificationFailed,
                               message: "Transaction signature did not verify: \(detail)")
        case .notAvailableInStorefront:
            return BridgeError(code: .notAvailableInStorefront,
                               message: "Product not sold in current storefront")
        case .networkError(let underlying):
            return BridgeError(code: .networkError,
                               message: "App Store unreachable: \(String(describing: underlying))")
        case .invalidPayload(let detail):
            return BridgeError(code: .invalidPayload, message: detail)
        case .underlying(let error):
            return BridgeError(code: .purchaseFailed, message: String(describing: error))
        }
    }
    #endif // canImport(StoreKit)
}

#endif // canImport(WebKit) && canImport(UIKit)
