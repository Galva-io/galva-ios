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
//  Everything else in this file is private payload parsing
//  (`ParsedPurchaseRequest`, `parsePurchaseRequest`,
//  `parsePromotionalOffer`). Outcome / failure encoding and controller
//  dispatch live in `PurchaseBridgeCodec` (host-testable on macOS). Add a
//  new purchase-related helper here rather than touching the core bridge
//  file.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import StoreKit

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
    ///
    /// When the host installed a `GalvaPurchaseController`, the purchase
    /// runs through it instead of StoreKit directly; the response shape is
    /// identical either way.
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

        // 2. Snapshot the SDK's attribution token across the actor hop.
        let appAccountToken = await identity.purchaseAttributionToken
        let controller = PurchaseControllerRegistry.current

        logger.info(.purchases, "bridge requestPurchase", metadata: [
            "productId": parsed.productId,
            "messageId": activeMessageId,
            "promo": parsed.promotionalOffer == nil ? "false" : "true",
            "controller": controller.map { String(describing: type(of: $0)) } ?? "storekit",
        ])

        // 3a. Host-installed controller (RevenueCat, in-house billing, …).
        //     It can still reach the built-in StoreKit flow through
        //     `purchaseWithStoreKit()` — e.g. for a Galva-signed offer its
        //     billing SDK can't apply.
        if let controller {
            let prefetcher = storeKitPrefetcher
            let logger = self.logger
            let request = Galva.PurchaseRequest(
                productId: parsed.productId,
                promotionalOffer: parsed.promotionalOffer,
                appAccountToken: appAccountToken,
                messageId: activeMessageId,
                storeKitPurchase: {
                    do {
                        return try await StoreKitPurchaser(prefetcher: prefetcher, logger: logger)
                            .performPurchase(
                                productId: parsed.productId,
                                promotionalOffer: parsed.promotionalOffer,
                                appAccountToken: appAccountToken
                            )
                    } catch let failure as StoreKitPurchaser.Failure {
                        throw failure.publicError
                    }
                }
            )
            return await PurchaseBridgeCodec.run(request, with: controller, logger: logger)
        }

        // 3b. Built-in path — hand off to the typed StoreKit wrapper. Throws
        //     on real failures; flow outcomes (cancelled / pending) come back
        //     as success results.
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
            return .success(.object(PurchaseBridgeCodec.encode(outcome)))
        } catch let failure as StoreKitPurchaser.Failure {
            return .failure(PurchaseBridgeCodec.bridgeError(for: failure))
        } catch {
            return .failure(BridgeError(
                code: .purchaseFailed,
                message: String(describing: error)
            ))
        }
    }

    // MARK: - Purchase payload parsing

    private struct ParsedPurchaseRequest {
        let productId: String
        let promotionalOffer: StoreKitPurchaser.PromotionalOffer?
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
    }

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
}

#endif // canImport(WebKit) && canImport(UIKit)
