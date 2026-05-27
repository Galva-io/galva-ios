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

    init(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        logger: any GalvaLogger
    ) {
        self.messageManager = messageManager
        self.identity = identity
        self.logger = logger
    }

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
            return handleRequestPurchase(payload: envelope.payload, activeMessageId: active)

        case .openManageSubscription:
            return openURL(from: envelope.payload, key: "url", logTag: "openManageSubscription")

        case .openDeepLink:
            return openURL(from: envelope.payload, key: "url", logTag: "openDeepLink")
        }
    }

    // MARK: - Specific handlers

    private func handleRequestPurchase(
        payload: [String: AnyJSONValue]?,
        activeMessageId: String
    ) -> Result<AnyJSONValue?, BridgeError> {
        guard let payload,
              case .string(let productId)? = payload["productId"],
              !productId.isEmpty else {
            return .failure(BridgeError(code: .invalidPayload, message: "Missing productId"))
        }
        // StoreKit 2 integration ships in a follow-up — the bridge surface
        // is stable, so the bundle can already wire up its `requestPurchase`
        // calls. For now we acknowledge the request, log it, and return a
        // typed `productUnavailable` error so the bundle's UX can surface
        // a graceful "try again later" state.
        logger.info(.identity, "bridge requestPurchase (stub)", metadata: [
            "productId": productId,
            "messageId": activeMessageId,
        ])
        return .failure(BridgeError(
            code: .productUnavailable,
            message: "Native purchase flow not yet wired — coming in a follow-up SDK release"
        ))
    }

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
            safeArea: safe
        )
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
