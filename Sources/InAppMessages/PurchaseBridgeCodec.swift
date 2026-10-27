//
//  PurchaseBridgeCodec.swift
//  Galva
//
//  Decodes `requestPurchase` payloads, encodes their results into the
//  bridge wire shape, and runs host-installed `GalvaPurchaseController`s.
//
//  Surface:
//    • `decodeRequest(_:)` — bridge `payload` → product id + offer
//    • `encode(_:)`        — StoreKit outcome → bridge `result` payload
//    • `bridgeError(for:)` — internal `StoreKitPurchaser.Failure` or public
//                            `Galva.PurchaseError` → structured `BridgeError`
//    • `run(_:with:logger:)` — drive a controller, encode its result
//
//  Split out of `NativeBridge+Purchases.swift` (UIKit + WebKit only) so the
//  decoding and encoding are host-testable under `swift test` on macOS. Both
//  the built-in StoreKit path and the controller path go through here, so
//  the bundle sees one wire format whichever ran the purchase.
//

import Foundation
import StoreKit

enum PurchaseBridgeCodec {

    // MARK: - Request decoding

    /// A decoded `requestPurchase` payload.
    struct Request: Equatable {
        let productId: String
        let promotionalOffer: StoreKitPurchaser.PromotionalOffer?
    }

    /// Decode a `requestPurchase` payload. `productId` is required.
    /// `promotionalOffer` is optional — absent or null both mean "no offer,
    /// standard list-price purchase" — but needs its `offerId` when present:
    /// a partial offer is rejected rather than quietly dropped, since the
    /// message promised the user a discount and a list-price purchase would
    /// surprise them. Its `signature` may be missing: Galva's backend leaves
    /// it out when the app has no In-App Purchase key in Galva, for a
    /// purchase controller that has the offer signed elsewhere.
    static func decodeRequest(_ payload: [String: AnyJSONValue]?) -> Result<Request, BridgeError> {
        guard let payload,
              case .string(let productId)? = payload["productId"],
              !productId.isEmpty else {
            return .failure(BridgeError(
                code: .invalidPayload,
                message: "Missing productId"
            ))
        }

        let promo: StoreKitPurchaser.PromotionalOffer?
        switch payload["promotionalOffer"] {
        case .object(let promoObj)?:
            switch decodePromotionalOffer(promoObj) {
            case .success(let p): promo = p
            case .failure(let err): return .failure(err)
            }
        case .null?, nil:
            promo = nil
        default:
            return .failure(BridgeError(
                code: .invalidPayload,
                message: "promotionalOffer must be an object"
            ))
        }
        return .success(Request(productId: productId, promotionalOffer: promo))
    }

    /// The JWS-only promotional offer payload: `offerId`, and the
    /// `signature` (a JWS compact string) when Galva signed the offer.
    private static func decodePromotionalOffer(
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
        let jws = string("signature") ?? string("compactJWS")
        return .success(.init(offerId: offerId, compactJWS: jws))
    }

    // MARK: - Controller dispatch

    /// Run `request` through a host-installed controller and encode the
    /// result exactly like the built-in StoreKit path. Never throws — every
    /// failure comes back as a structured `BridgeError`.
    @MainActor
    static func run(
        _ request: Galva.PurchaseRequest,
        with controller: any GalvaPurchaseController,
        logger: any GalvaLogger
    ) async -> Result<AnyJSONValue?, BridgeError> {
        do {
            let result = try await controller.purchase(request)
            return .success(.object(encode(StoreKitPurchaser.Outcome(result))))
        } catch let error as Galva.PurchaseError {
            logger.info(.purchases, "purchase controller failed", metadata: [
                "productId": request.productId,
            ], error: error)
            return .failure(bridgeError(for: error))
        } catch StoreKitError.userCancelled {
            // A controller that drives StoreKit itself and lets its thrown
            // cancel (Apple ID sign-in dismissed) escape.
            return .success(.object(encode(.cancelled)))
        } catch {
            logger.warning(.purchases, "purchase controller threw a non-Galva error", metadata: [
                "productId": request.productId,
            ], error: error)
            return .failure(BridgeError(code: .purchaseFailed, message: String(describing: error)))
        }
    }

    // MARK: - Outcome encoding

    static func encode(
        _ outcome: StoreKitPurchaser.Outcome
    ) -> [String: AnyJSONValue] {
        switch outcome {
        case .pending:
            return ["outcome": .string("pending")]
        case .cancelled:
            return ["outcome": .string("cancelled")]
        case .completed(let transactionId, let originalId,
                        let productId, let purchaseDate, let expirationDate,
                        let appAccountToken):
            var transaction: [String: AnyJSONValue] = [
                "id":                  .string(String(transactionId)),
                "originalId":          .string(String(originalId)),
                "productId":           .string(productId),
                "purchaseDate":        .string(ISO8601DateFormatter.galva.string(from: purchaseDate)),
                "verified":            .bool(true),
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

    // MARK: - Failure mapping

    static func bridgeError(
        for failure: StoreKitPurchaser.Failure
    ) -> BridgeError {
        switch failure {
        case .invalidPayload(let detail):
            return BridgeError(code: .invalidPayload, message: detail)
        default:
            return bridgeError(for: failure.publicError)
        }
    }

    static func bridgeError(for error: Galva.PurchaseError) -> BridgeError {
        switch error {
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
        case .networkError(let detail):
            return BridgeError(code: .networkError,
                               message: "App Store unreachable: \(detail)")
        case .failed(let detail):
            return BridgeError(code: .purchaseFailed, message: detail)
        }
    }
}
