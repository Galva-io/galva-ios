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
//      • Unknown method names are never dispatched — they resolve to
//        `BridgeRequest.method == nil` and are answered with a structured
//        `unknownMethod` error (carrying the `requestId`) so the bundle's
//        pending Promise rejects cleanly instead of hanging.
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

    /// Whoever owns the WebView presentation — `InAppMessagePresenter`
    /// for the UIKit path, `InAppMessageSheetCoordinator` for SwiftUI.
    /// The bridge stays platform-agnostic by talking through the
    /// `InAppMessageHost` protocol.
    weak var host: (any InAppMessageHost)?

    /// Forwards WebView `console.*` output to the SDK logger when debug
    /// logging is enabled. Held strongly here — the bridge is retained by the
    /// host for the presentation's lifetime, whereas
    /// `WKUserContentController.add(_:name:)` keeps only a weak reference to
    /// script-message handlers. `nil` outside debug logging.
    var consoleLogHandler: WebViewConsoleLogHandler?

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
            "name": envelope.name,
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
        // Unknown method → structured error (with the requestId, via respond)
        // so the bundle's pending Promise rejects instead of hanging.
        guard let method = envelope.method else {
            logger.warning(.identity, "bridge: unknown method", metadata: ["name": envelope.name])
            return .failure(BridgeError(
                code: .unknownMethod,
                message: "Unknown bridge method: \(envelope.name)"
            ))
        }
        switch method {
        case .ready:
            host?.reveal()
            return .success(nil)

        case .dismiss:
            let reason = envelope.payload?["reason"].flatMap { value -> String? in
                if case .string(let s) = value { return s } else { return nil }
            }
            host?.dismiss(reason: reason)
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

        case .apiFetch:
            return await handleAPIFetch(payload: envelope.payload)

        case .showAlert:
            return await handleShowAlert(payload: envelope.payload)
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

    // MARK: - apiFetch (WebView → Galva API proxy)

    /// Proxy an HTTP request from the hosted page to the Galva API.
    ///
    /// Wire payload (only `path` is required):
    ///     {
    ///       "path":    "/identities/…/something",   // relative path
    ///       "method":  "POST",                       // default "GET"
    ///       "body":    { … } | "raw string",         // object → JSON body
    ///       "headers": { "Accept": "application/json" }
    ///     }
    ///
    /// The SDK prepends the API base URL, injects the API key (the bundle
    /// can neither see nor override it), and refuses any path that escapes
    /// the API origin.
    ///
    /// Resolves (fetch-style) for ANY completed round-trip — including
    /// 4xx / 5xx — with:
    ///     {
    ///       "status": 200, "ok": true,
    ///       "headers": { "content-type": "application/json", … },
    ///       "body": <parsed JSON | string>,
    ///       "bodyType": "json" | "text" | "base64"
    ///     }
    ///
    /// Rejects only on a malformed / disallowed path (`invalidPayload`) or a
    /// transport-layer failure (`apiRequestFailed`).
    private func handleAPIFetch(
        payload: [String: AnyJSONValue]?
    ) async -> Result<AnyJSONValue?, BridgeError> {
        let parsed: ParsedAPIFetch
        switch Self.parseAPIFetch(payload) {
        case .success(let value): parsed = value
        case .failure(let error): return .failure(error)
        }
        logger.debug(.identity, "bridge apiFetch", metadata: [
            "method": parsed.method,
            "path": parsed.path,
            "shouldRetry": parsed.shouldRetry ? "true" : "false",
        ])

        // Fire-and-forget durable path: persist for guaranteed eventual
        // delivery (retries across network loss + app launches) and ack the
        // bundle immediately — it does NOT wait for the HTTP response.
        if parsed.shouldRetry {
            let queued = await messageManager.enqueueDurableProxyRequest(
                path: parsed.path,
                method: parsed.method,
                body: parsed.body,
                additionalHeaders: parsed.headers
            )
            guard queued else {
                return .failure(BridgeError(
                    code: .apiRequestFailed,
                    message: "Durable request queue unavailable"
                ))
            }
            return .success(.object(["queued": .bool(true)]))
        }

        do {
            let response = try await messageManager.apiProxyFetch(
                path: parsed.path,
                method: parsed.method,
                body: parsed.body,
                additionalHeaders: parsed.headers
            )
            // Encode the typed result straight to the wire `[String: AnyJSONValue]`
            // via the shared `toJSON` helper — same path `getPageContext` uses.
            return .success(.object(Self.toJSON(Self.encodeAPIResponse(response))))
        } catch let apiError as APIError {
            switch apiError {
            case .malformedURL:
                return .failure(BridgeError(
                    code: .invalidPayload,
                    message: "apiFetch path is invalid or targets a disallowed origin"
                ))
            default:
                return .failure(BridgeError(
                    code: .apiRequestFailed,
                    message: "apiFetch transport error: \(String(describing: apiError))"
                ))
            }
        } catch {
            return .failure(BridgeError(
                code: .apiRequestFailed,
                message: "apiFetch failed: \(String(describing: error))"
            ))
        }
    }

    /// Parsed + validated `apiFetch` request. Internal (not private) so the
    /// pure parse / encode logic can be unit-tested without a live WebView.
    struct ParsedAPIFetch: Equatable {
        let path: String
        let method: String
        let body: Data?
        let headers: [String: String]
        /// When `true`, the bundle is firing-and-forgetting: the SDK persists
        /// the request and guarantees eventual delivery (retries across
        /// network outages and app launches) rather than awaiting it inline.
        let shouldRetry: Bool
    }

    /// HTTP methods the bundle may proxy. Conservative allowlist — anything
    /// else is rejected as `invalidPayload`.
    static let apiFetchAllowedMethods: Set<String> =
        ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    /// Decode the `apiFetch` payload into a validated request. Pure +
    /// static for testability.
    static func parseAPIFetch(
        _ payload: [String: AnyJSONValue]?
    ) -> Result<ParsedAPIFetch, BridgeError> {
        guard let payload,
              case .string(let path)? = payload["path"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "apiFetch requires a non-empty path"))
        }

        // Method — default GET, upper-cased, allowlisted.
        var method = "GET"
        if case .string(let raw)? = payload["method"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            method = raw.uppercased()
        }
        guard apiFetchAllowedMethods.contains(method) else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "apiFetch method not allowed: \(method)"))
        }

        // Additional headers — string→string only; non-string values dropped.
        var headers: [String: String] = [:]
        if case .object(let object)? = payload["headers"] {
            for (key, value) in object {
                if case .string(let stringValue) = value { headers[key] = stringValue }
            }
        }

        // Body — a string is sent as raw UTF-8; an object / array / scalar is
        // JSON-encoded with a default Content-Type of application/json
        // (unless the caller already set one). Absent / null → no body.
        var body: Data?
        switch payload["body"] {
        case .none, .some(.null):
            body = nil
        case .some(.string(let stringBody)):
            body = Data(stringBody.utf8)
        case .some(let jsonBody):
            guard let encoded = try? JSONEncoder().encode(jsonBody) else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "apiFetch body could not be encoded"))
            }
            body = encoded
            let hasContentType = headers.keys.contains {
                $0.caseInsensitiveCompare("Content-Type") == .orderedSame
            }
            if !hasContentType { headers["Content-Type"] = "application/json" }
        }

        // shouldRetry — opt-in durable, fire-and-forget delivery. Default false
        // (normal inline request the bundle awaits). Only an explicit `true`
        // boolean enables it.
        var shouldRetry = false
        if case .bool(let flag)? = payload["shouldRetry"] { shouldRetry = flag }

        return .success(ParsedAPIFetch(
            path: path, method: method, body: body, headers: headers, shouldRetry: shouldRetry
        ))
    }

    /// Map a raw `APIClient.ProxyResponse` into the typed `BridgeAPIFetchResult`.
    /// The body is decoded into a structured JSON value when the response
    /// advertises JSON (and actually parses), otherwise a UTF-8 string,
    /// otherwise base64 so binary payloads survive the trip. The typed result
    /// is what defines the wire shape — the caller encodes it via `toJSON`.
    /// Pure + static for testability.
    static func encodeAPIResponse(
        _ response: APIClient.ProxyResponse
    ) -> BridgeAPIFetchResult {
        let contentType = response.headers["content-type"]?.lowercased() ?? ""

        let body: AnyJSONValue
        let bodyType: BridgeAPIFetchResult.BodyType
        if !response.body.isEmpty,
           contentType.contains("json"),
           let decoded = try? JSONDecoder().decode(AnyJSONValue.self, from: response.body) {
            body = decoded
            bodyType = .json
        } else if let text = String(data: response.body, encoding: .utf8) {
            body = .string(text)
            bodyType = .text
        } else {
            body = .string(response.body.base64EncodedString())
            bodyType = .base64
        }

        return BridgeAPIFetchResult(
            status: response.status,
            ok: (200..<300).contains(response.status),
            headers: response.headers,
            body: body,
            bodyType: bodyType
        )
    }

    // MARK: - showAlert (system UIAlertController)

    /// Present a system `UIAlertController` on behalf of the hosted page.
    ///
    /// Wire payload:
    ///     {
    ///       "title":   "Delete draft?",      // optional
    ///       "message": "This can't be undone", // optional
    ///       "actions": [                       // required, non-empty
    ///         { "id": "delete", "title": "Delete", "style": "destructive" },
    ///         { "id": "cancel", "title": "Cancel", "style": "cancel" }
    ///       ]
    ///     }
    ///
    /// `style` is `"default"` (the default), `"cancel"`, or `"destructive"`.
    /// UIKit permits at most one cancel action, so 2+ are rejected as
    /// `invalidPayload` rather than crashing the host app.
    ///
    /// The call suspends until the user taps an action, then resolves with
    /// `{ "actionId": "<the tapped action's id>" }`.
    private func handleShowAlert(
        payload: [String: AnyJSONValue]?
    ) async -> Result<AnyJSONValue?, BridgeError> {
        let parsed: ParsedAlert
        switch Self.parseAlert(payload) {
        case .success(let value): parsed = value
        case .failure(let error): return .failure(error)
        }
        guard let presenter = presentingViewController() else {
            return .failure(BridgeError(
                code: .noActiveMessage,
                message: "No view controller available to present the alert"
            ))
        }
        logger.info(.identity, "bridge showAlert", metadata: [
            "actions": String(parsed.actions.count),
        ])
        // Suspend until the user taps; each action handler resumes exactly
        // once (an `.alert` with ≥1 action is only dismissible by a tap).
        let actionId: String = await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: parsed.title,
                message: parsed.message,
                preferredStyle: .alert
            )
            for action in parsed.actions {
                alert.addAction(UIAlertAction(title: action.title, style: action.style) { _ in
                    continuation.resume(returning: action.id)
                })
            }
            presenter.present(alert, animated: true)
        }
        return .success(.object(Self.toJSON(BridgeAlertResult(actionId: actionId))))
    }

    /// Parsed, validated `showAlert` request. Internal (not private) so the
    /// pure parse logic can be unit-tested without presenting UIKit.
    struct ParsedAlert: Equatable {
        let title: String?
        let message: String?
        let actions: [Action]

        struct Action: Equatable {
            let id: String
            let title: String
            let style: UIAlertAction.Style
        }
    }

    static func parseAlert(
        _ payload: [String: AnyJSONValue]?
    ) -> Result<ParsedAlert, BridgeError> {
        guard let payload else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "showAlert requires a payload"))
        }
        // title / message are optional; a non-string value is treated as absent.
        let title = Self.alertString(payload["title"])
        let message = Self.alertString(payload["message"])

        guard case .array(let rawActions)? = payload["actions"], !rawActions.isEmpty else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "showAlert requires a non-empty actions array"))
        }
        var actions: [ParsedAlert.Action] = []
        for raw in rawActions {
            guard case .object(let object) = raw else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "showAlert action must be an object"))
            }
            guard let id = Self.alertString(object["id"]), !id.isEmpty else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "showAlert action requires a non-empty id"))
            }
            guard let actionTitle = Self.alertString(object["title"]), !actionTitle.isEmpty else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "showAlert action requires a non-empty title"))
            }
            actions.append(.init(id: id, title: actionTitle, style: Self.alertStyle(object["style"])))
        }
        // UIKit raises an exception if more than one `.cancel` action is added —
        // reject that here so a bundle bug can't crash the host app.
        guard actions.filter({ $0.style == .cancel }).count <= 1 else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "showAlert allows at most one cancel action"))
        }
        return .success(ParsedAlert(title: title, message: message, actions: actions))
    }

    private static func alertString(_ value: AnyJSONValue?) -> String? {
        if case .string(let string)? = value { return string } else { return nil }
    }

    private static func alertStyle(_ value: AnyJSONValue?) -> UIAlertAction.Style {
        guard case .string(let raw)? = value else { return .default }
        switch raw.lowercased() {
        case "cancel":      return .cancel
        case "destructive": return .destructive
        default:            return .default
        }
    }

    /// The view controller to present an alert from: the WebView's owning VC
    /// (via the responder chain), descended to its top-most presented VC so
    /// the alert layers above the in-app message sheet. Works for both the
    /// UIKit and SwiftUI hosts since both mount the WebView inside a VC.
    private func presentingViewController() -> UIViewController? {
        guard let webView = host?.webView else { return nil }
        var responder: UIResponder? = webView
        while let current = responder {
            if let viewController = current as? UIViewController {
                var top = viewController
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = current.next
        }
        return nil
    }

    // MARK: - Page context

    private func makePageContext(messageId: String) async -> BridgePageContext {
        let safe = safeAreaInsets()
        let pushAuth = await currentPushAuthorization()
        let app = appBundleInfo()
        let storefrontCode = await currentStorefrontCountryCode()
        // Same UUID the SDK attaches to Galva-initiated StoreKit purchases —
        // override from identify(userId:appAccountToken:) or the anonymousId
        // as a UUID. Hand it to the bundle so its own purchase/attribution
        // calls reconcile to the same account.
        let appAccountToken = await identity.purchaseAttributionToken
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
            storefrontCountryCode: storefrontCode,
            appAccountToken: appAccountToken.uuidString.lowercased()
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
        // Delegate to the host — each host computes insets from whichever
        // view it owns (UIKit VC's view, or the SwiftUI sheet's hosting
        // view). The insets reflect the *presented sheet's* safe area,
        // which is what the bundle needs to pad against (grabber +
        // dynamic island + home indicator), NOT the under-sheet host
        // window's insets.
        let insets = host?.safeAreaInsets ?? .zero
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

    /// Pure enum mapper — called from the `UNUserNotificationCenter`
    /// completion handler, which is `@Sendable` and nonisolated. Marking
    /// the function `nonisolated` drops the `@MainActor` inheritance the
    /// surrounding class would otherwise impose, so the call site
    /// doesn't need an isolation hop.
    nonisolated private static func mapAuthorization(
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
        guard let webView = host?.webView else { return }
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
