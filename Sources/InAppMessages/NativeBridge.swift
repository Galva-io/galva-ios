//
//  NativeBridge.swift
//  Galva
//
//  WKScriptMessageHandler that decodes incoming bridge envelopes from the
//  hosted WebView bundle, dispatches each method on the main actor, and
//  posts the response back via
//  `WKWebView.evaluateJavaScript("window.handleNativeMessage('…')")`.
//
//  Layout (split across feature-scoped files so each method's handler +
//  parsing + encoding sit together; the dispatch table here is the only
//  index you have to read to find them)
//      • `NativeBridge.swift`            — properties, init, dispatch,
//                                          response, shared helpers
//      • `NativeBridge+Purchases.swift`  — handleRequestPurchase + StoreKit
//      • `NativeBridge+APIFetch.swift`   — handleAPIFetch + parse / encode
//      • `NativeBridge+ShowAlert.swift`  — handleShowAlert + parse + gate
//      • `NativeBridge+OpenURL.swift`    — openURL (open-manage-sub + deep-link)
//      • `NativeBridge+PageContext.swift`— makePageContext + device probes
//
//  Adding a new bridge method: extend `BridgeMethod` in `BridgeProtocol`,
//  add a case to the `handle(envelope:)` switch below, and put the
//  handler + its private parsing / encoding in a new
//  `NativeBridge+<Method>.swift` extension.
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
    /// logging is enabled. Held strongly here so
    /// `InAppMessageWebViewFactory.tearDown(webView:bridge:)` has one place
    /// to release the handler alongside its
    /// `removeScriptMessageHandler(forName:)` call — without this property,
    /// an in-flight bridge dispatch Task keeping the bridge alive past
    /// dismiss would also keep the console handler alive. `nil` outside
    /// debug logging.
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
    //
    // The single routing table for every bridge method. Each `case` here
    // delegates to a handler defined in the per-feature extension file
    // listed in the header comment above. Keep this table small + flat
    // so it stays readable as new methods are added.

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

    // MARK: - Shared helpers
    //
    // `toJSON` and `escapeForJSStringLiteral` are reached from per-feature
    // extension files (they need module-internal visibility, not
    // file-`private`). `decodeEnvelope` stays private — it's only used by
    // `userContentController` above.

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
    static func toJSON<T: Encodable>(_ value: T) -> [String: AnyJSONValue] {
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
