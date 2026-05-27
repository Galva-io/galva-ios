//
//  BridgeProtocol.swift
//  Galva
//
//  Wire-format envelopes for the WebView ↔ native bridge.
//
//  Outbound (bundle → native), single channel
//  `webkit.messageHandlers.galva.postMessage(jsonString)`:
//      {
//        "name":      "ready" | "dismiss" | "getPageContext" | …,
//        "requestId": "<uuid v4>",
//        "payload":   { …method-specific args, possibly empty… }
//      }
//
//  Inbound response (native → bundle), single JS function
//  `window.handleNativeMessage(jsonString)`:
//      {
//        "requestId": "<echoed verbatim>",
//        "result":    <any JSON-supported value>
//      }
//
//  Error responses replace `result` with `{ "error": { code, message } }`
//  so the bundle's pending-Promise registry can `reject()` cleanly.
//
//  Per the docs, every outbound call (including fire-and-forget `ready`)
//  receives a response so the bundle's request map drains; we honour that
//  by replying with `null` for void methods.
//

import Foundation

/// Outbound (bundle → native) envelope.
struct BridgeRequest: Sendable, Hashable, Codable {
    let name: BridgeMethod
    let requestId: String
    let payload: [String: AnyJSONValue]?
}

/// Inbound (native → bundle) response envelope. `result` is always present
/// for successful calls; `error` is set instead on failure.
struct BridgeResponse: Sendable, Hashable, Codable {
    let requestId: String
    let result: AnyJSONValue?
    let error: BridgeError?

    init(requestId: String, result: AnyJSONValue?) {
        self.requestId = requestId
        self.result = result
        self.error = nil
    }

    init(requestId: String, error: BridgeError) {
        self.requestId = requestId
        self.result = nil
        self.error = error
    }
}

/// Structured error returned to the bundle when a bridge call fails. The
/// `code` field is the contract — message is for developer-console
/// diagnostics only and may shift across SDK releases.
///
/// Conforms to `Error` so it can be carried by `Result<…, BridgeError>`
/// at the dispatch layer.
struct BridgeError: Error, Sendable, Hashable, Codable {
    let code: Code
    let message: String

    enum Code: String, Sendable, Hashable, Codable {
        /// Bundle called a method the SDK doesn't recognize.
        case unknownMethod
        /// Bundle called a method that requires an active message and there
        /// isn't one (e.g. requestPurchase on a closed overlay).
        case noActiveMessage
        /// Bundle called requestPurchase with an unknown `productId`.
        case productUnavailable
        /// Bundle requested data the SDK couldn't resolve from its cache.
        case messageDataUnavailable
        /// Bundle passed a malformed payload.
        case invalidPayload
        /// SDK exceeded the bridge call timeout.
        case timeout
        /// StoreKit purchase prompt failed before completion.
        case purchaseFailed
        /// `openManageSubscription` / `openDeepLink` URL couldn't be opened.
        case urlOpenFailed
    }
}

/// Strict allowlist of native bridge methods. The decoder rejects any
/// unknown value so a malicious bundle can't probe the dispatch surface.
enum BridgeMethod: String, Sendable, Hashable, Codable {
    /// Anti-FOUC: reveal the overlay window after the bundle's first paint.
    case ready
    /// Close the overlay. Payload may carry `{ "reason": "..." }`.
    case dismiss
    /// Return identity / locale / safe-area / sessionToken context.
    case getPageContext
    /// Return the cached resolved-communication payload.
    case getMessageData
    /// Trigger native StoreKit 2 purchase prompt.
    case requestPurchase
    /// Open the storefront's manage-subscription URL.
    case openManageSubscription
    /// Hand a deep link back to the host app.
    case openDeepLink
}

// MARK: - Page context (returned by `getPageContext`)

/// Bridge response body for `galva.getPageContext()`. Keys match the names
/// the hosted page consumes verbatim per the docs — do NOT rename without
/// coordinating a `bridgeProtocolVersion` bump.
struct BridgePageContext: Sendable, Hashable, Codable {
    let messageId: String
    let sessionToken: String?
    let bridgeProtocol: String
    let sdkVersion: String
    let platform: String
    let appVersion: String?
    let appBuild: String?
    let pushAuthorization: PushAuthorization?
    let locale: String
    let appColorScheme: AppColorScheme?
    let safeArea: SafeArea

    enum PushAuthorization: String, Sendable, Hashable, Codable {
        case notDetermined, denied, authorized, provisional, ephemeral
    }

    enum AppColorScheme: String, Sendable, Hashable, Codable {
        case light, dark
    }

    struct SafeArea: Sendable, Hashable, Codable {
        let top: Double
        let bottom: Double
        let left: Double
        let right: Double
    }
}
