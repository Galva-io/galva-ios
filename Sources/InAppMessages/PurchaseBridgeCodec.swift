//
//  PurchaseBridgeCodec.swift
//  Galva
//
//  Encodes `requestPurchase` results into the bridge wire shape, and runs
//  host-installed `GalvaPurchaseController`s.
//
//  Surface:
//    • `encode(_:)`        — StoreKit outcome → bridge `result` payload
//    • `bridgeError(for:)` — internal `StoreKitPurchaser.Failure` or public
//                            `Galva.PurchaseError` → structured `BridgeError`
//    • `run(_:with:logger:)` — drive a controller, encode its result
//
//  Split out of `NativeBridge+Purchases.swift` (UIKit + WebKit only) so the
//  encoding is host-testable under `swift test` on macOS. Both the built-in
//  StoreKit path and the controller path go through here, so the bundle sees
//  one wire format whichever ran the purchase.
//

import Foundation
#if canImport(StoreKit)
import StoreKit

enum PurchaseBridgeCodec {

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
            logger.info(.identity, "purchase controller failed", metadata: [
                "productId": request.productId,
            ], error: error)
            return .failure(bridgeError(for: error))
        } catch StoreKitError.userCancelled {
            // A controller that drives StoreKit itself and lets its thrown
            // cancel (Apple ID sign-in dismissed) escape.
            return .success(.object(encode(.cancelled)))
        } catch {
            logger.warning(.identity, "purchase controller threw a non-Galva error", metadata: [
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

#endif // canImport(StoreKit)
