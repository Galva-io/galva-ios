//
//  NativeBridge.swift
//  Galva
//
//  WKScriptMessageHandler that decodes incoming bridge envelopes from the
//  hosted WebView bundle, dispatches each method on the main actor, and
//  posts the response back via
//  `WKWebView.evaluateJavaScript("window.handleNativeMessage('…')")`.
//
//  Layout
//      • `NativeBridge` (this file) — wire decode, dispatch, response.
//      • `InAppMessagePresenter` — owns the WKWebView + overlay window.
//      • `InAppMessageManager` — owns resolve payload cache + activeMessageId.
//
//  Threading
//      • `WKScriptMessageHandler` is `@MainActor` in the WebKit headers.
//        Calls into the GalvaActor-isolated message manager are awaited
//        explicitly through accessor methods on the manager.
//
//  Security
//      • The script-message handler name is `galva` — that one inbound
//        channel is the entire native attack surface.
//      • `BridgeMethod`'s exhaustive `Codable` enum rejects unknown method
//        names before they reach the dispatcher.
//      • The response JSON is escaped before being spliced into the
//        evaluateJavaScript source so payload content cannot break out of
//        the JS string literal.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(WebKit) && canImport(UIKit)

/// Handler name registered on `WKUserContentController` and reached from
/// JS as `webkit.messageHandlers.galva.postMessage(jsonString)`.
let kGalvaBridgeHandlerName = "galva"

@MainActor
final class NativeBridge: NSObject, WKScriptMessageHandler {

    weak var presenter: InAppMessagePresenter?
    let messageManager: InAppMessageManager
    let identity: IdentityStore
    let logger: any GalvaLogger

    #if canImport(StoreKit)
    /// Warm cache used by `requestPurchase` to skip a `Product.products(for:)`
    /// round-trip when the SDK already pre-fetched the SKU during
    /// `/sdk/initialize`. Optional — purchase still works without it
    /// (cold-path live fetch inside `StoreKitPurchaser`).
    let storeKitPrefetcher: StoreKitProductPrefetcher?
    #endif

    #if canImport(StoreKit)
    init(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        storeKitPrefetcher: StoreKitProductPrefetcher?,
        logger: any GalvaLogger
    ) {
        self.messageManager = messageManager
        self.identity = identity
        self.storeKitPrefetcher = storeKitPrefetcher
        self.logger = logger
    }
    #else
    init(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        logger: any GalvaLogger
    ) {
        self.messageManager = messageManager
        self.identity = identity
        self.logger = logger
    }
    #endif

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == kGalvaBridgeHandlerName else { return }
        let envelope: BridgeRequest
        do {
            envelope = try Self.decodeEnvelope(message.body)
        } catch {
            logger.warning(.identity, "bridge: failed to decode envelope", error: error)
            return
        }
        logger.debug(.identity, "bridge in", metadata: [
            "name": envelope.name.rawValue,
            "requestId": envelope.requestId,
        ])
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.handle(envelope: envelope)
            await self.respond(requestId: envelope.requestId, outcome: outcome)
        }
    }

    // MARK: - Dispatch

    private func handle(envelope: BridgeRequest) async -> Result<AnyJSONValue?, BridgeError> {
        switch envelope.name {
        case .ready:
            presenter?.reveal()
            return .success(nil)

        case .dismiss:
            let reason = envelope.payload?["reason"].flatMap { value -> String? in
                if case .string(let s) = value { return s } else { return nil }
            }
            presenter?.dismiss(reason: reason)
            return .success(nil)

        case .getPageContext:
            guard let messageId = await messageManager.currentActiveMessageId() else {
                return .failure(BridgeError(code: .noActiveMessage, message: "No active message"))
            }
            let context = await makePageContext(messageId: messageId)
            return .success(.object(Self.toJSON(context)))

        case .getMessageData:
            guard let messageId = await messageManager.currentActiveMessageId() else {
                return .failure(BridgeError(code: .noActiveMessage, message: "No active message"))
            }
            guard let valid = await messageManager.payload(for: messageId) else {
                return .failure(BridgeError(
                    code: .messageDataUnavailable,
                    message: "Resolved payload not available — call show(in:) first"
                ))
            }
            return .success(.object(valid.payload.json))

        case .requestPurchase:
            guard let active = await messageManager.currentActiveMessageId() else {
                return .failure(BridgeError(code: .noActiveMessage, message: "No active message"))
            }
            return await handleRequestPurchase(
                payload: envelope.payload,
                activeMessageId: active
            )

        case .openManageSubscription:
            return openURL(from: envelope.payload, key: "url", logTag: "openManageSubscription")

        case .openDeepLink:
            return openURL(from: envelope.payload, key: "url", logTag: "openDeepLink")
        }
    }

    // MARK: - Specific handlers

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
    private func handleRequestPurchase(
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
        // Light sanity check on the JWS shape — three non-empty base64url
        // segments. Catching obvious junk here gives the bundle a precise
        // error instead of letting StoreKit surface a generic
        // invalidOfferSignature failure deep in the purchase flow.
        guard Self.isLikelyJWS(jws) else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "promotionalOffer.signature is not a JWS compact string"))
        }
        return .success(.init(offerId: offerId, compactJWS: jws))
    }

    /// True when `s` looks like a JWS compact serialization
    /// (`<header>.<payload>.<signature>` — three non-empty base64url
    /// segments separated by `.`). Conservative — we don't try to decode
    /// or validate the cryptography here.
    static func isLikelyJWS(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for part in parts where part.isEmpty
            || part.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return false
        }
        return true
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
                transaction["appAccountToken"] = .string(tok.uuidString)
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

    private func openURL(
        from payload: [String: AnyJSONValue]?,
        key: String,
        logTag: String
    ) -> Result<AnyJSONValue?, BridgeError> {
        guard let payload,
              case .string(let raw)? = payload[key],
              let url = URL(string: raw) else {
            return .failure(BridgeError(code: .invalidPayload, message: "Missing or malformed URL"))
        }
        let app = UIApplication.shared
        guard app.canOpenURL(url) else {
            logger.warning(.identity, "bridge \(logTag): URL not openable", metadata: ["url": raw])
            return .failure(BridgeError(code: .urlOpenFailed, message: "URL cannot be opened"))
        }
        app.open(url, options: [:]) { [weak self] success in
            // UIApplication.open(_:options:completionHandler:) calls back
            // on the main thread per UIKit contract — safe to touch self.
            MainActor.assumeIsolated {
                if success {
                    self?.logger.debug(.identity, "bridge \(logTag) opened", metadata: ["url": raw])
                } else {
                    self?.logger.warning(.identity, "bridge \(logTag) failed", metadata: ["url": raw])
                }
            }
        }
        return .success(.bool(true))
    }

    // MARK: - Page context

    private func makePageContext(messageId: String) async -> BridgePageContext {
        let safe = safeAreaInsets()
        let pushAuth = await currentPushAuthorization()
        let app = appBundleInfo()
        let storefrontCode = await currentStorefrontCountryCode()
        return BridgePageContext(
            messageId: messageId,
            sessionToken: nil, // signed token attaches in a follow-up; bundle reads as-nil-safe
            bridgeProtocol: SDKConstants.bridgeProtocolVersion,
            sdkVersion: SDKConstants.version,
            platform: "ios",
            appVersion: app.version,
            appBuild: app.build,
            pushAuthorization: pushAuth,
            locale: Locale.current.identifier,
            appColorScheme: nil, // SDK doesn't override; bundle falls back to matchMedia
            safeArea: safe,
            storefrontCountryCode: storefrontCode
        )
    }

    /// ISO 3166-1 alpha-3 storefront code (`"USA"`, `"GBR"`, `"JPN"`,
    /// etc.) from `StoreKit.Storefront.current`. Returns `nil` when
    /// StoreKit isn't reachable (Simulator without StoreKit config,
    /// device hasn't signed into the App Store, sandbox issues). The
    /// bundle uses this to pick storefront-specific copy without an
    /// extra bridge round-trip.
    private func currentStorefrontCountryCode() async -> String? {
        #if canImport(StoreKit)
        return await Storefront.current?.countryCode
        #else
        return nil
        #endif
    }

    private func appBundleInfo() -> (version: String?, build: String?) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String,
                info["CFBundleVersion"] as? String)
    }

    private func safeAreaInsets() -> BridgePageContext.SafeArea {
        // Read from the VC's view: it reflects the safe area the sheet
        // is actually drawing into (accounts for the grabber, sheet
        // chrome, and any presentation adjustments). The host window's
        // insets would describe the under-sheet content area, which is
        // not what the bundle needs to pad against.
        guard let view = presenter?.viewController?.view else {
            return .init(top: 0, bottom: 0, left: 0, right: 0)
        }
        let insets = view.safeAreaInsets
        return .init(
            top: Double(insets.top),
            bottom: Double(insets.bottom),
            left: Double(insets.left),
            right: Double(insets.right)
        )
    }

    private func currentPushAuthorization() async -> BridgePageContext.PushAuthorization {
        await withCheckedContinuation { (cont: CheckedContinuation<BridgePageContext.PushAuthorization, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: Self.mapAuthorization(settings.authorizationStatus))
            }
        }
    }

    private static func mapAuthorization(
        _ status: UNAuthorizationStatus
    ) -> BridgePageContext.PushAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .provisional:   return .provisional
        case .ephemeral:     return .ephemeral
        @unknown default:    return .notDetermined
        }
    }

    // MARK: - Response

    private func respond(
        requestId: String,
        outcome: Result<AnyJSONValue?, BridgeError>
    ) async {
        let response: BridgeResponse
        switch outcome {
        case .success(let value):
            response = BridgeResponse(requestId: requestId, result: value)
        case .failure(let error):
            response = BridgeResponse(requestId: requestId, error: error)
        }
        guard let presenter, let webView = presenter.webView else { return }
        let encoder = JSONEncoder()
        guard
            let data = try? encoder.encode(response),
            let jsonString = String(data: data, encoding: .utf8)
        else {
            logger.warning(.identity, "bridge: failed to encode response", metadata: [
                "requestId": requestId,
            ])
            return
        }
        let escaped = Self.escapeForJSStringLiteral(jsonString)
        let js = "window.handleNativeMessage('\(escaped)')"
        do {
            _ = try await webView.evaluateJavaScript(js)
            logger.debug(.identity, "bridge out", metadata: ["requestId": requestId])
        } catch {
            logger.warning(.identity, "bridge: evaluateJavaScript failed",
                           metadata: ["requestId": requestId],
                           error: error)
        }
    }

    // MARK: - Helpers

    /// WKScriptMessage.body can arrive as an NSDictionary (JS object) or as
    /// an NSString (some bundles wrap their envelope in a JSON.stringify).
    /// Decode both forms into BridgeRequest.
    private static func decodeEnvelope(_ body: Any) throws -> BridgeRequest {
        let data: Data
        if let string = body as? String, let raw = string.data(using: .utf8) {
            data = raw
        } else if JSONSerialization.isValidJSONObject(body) {
            data = try JSONSerialization.data(withJSONObject: body)
        } else {
            throw BridgeDecodeError.unsupportedBodyShape
        }
        return try JSONDecoder().decode(BridgeRequest.self, from: data)
    }

    /// Wrap the JSON-encoded response in single quotes for safe splicing
    /// into the evaluateJavaScript source. The bundle reads it back via
    /// JSON.parse, so we only need to neutralize characters that would
    /// break out of a single-quoted JS string literal.
    static func escapeForJSStringLiteral(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out.append("\\\\")
            case "'":  out.append("\\'")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\u{2028}": out.append("\\u2028") // JS line separator
            case "\u{2029}": out.append("\\u2029") // JS paragraph separator
            default:   out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Round-trip-encode an Encodable into a `[String: AnyJSONValue]` so
    /// the bridge can splice it into a single response envelope without a
    /// parallel encoder.
    private static func toJSON<T: Encodable>(_ value: T) -> [String: AnyJSONValue] {
        let encoder = JSONEncoder()
        guard
            let data = try? encoder.encode(value),
            let dict = try? JSONDecoder().decode([String: AnyJSONValue].self, from: data)
        else { return [:] }
        return dict
    }
}

// MARK: - Local error types

private enum BridgeDecodeError: Error { case unsupportedBodyShape }

#endif // canImport(WebKit) && canImport(UIKit)
