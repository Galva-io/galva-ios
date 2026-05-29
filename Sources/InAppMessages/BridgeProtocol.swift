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
    /// Raw method name as sent by the bundle. Decoded as a `String` (not a
    /// `BridgeMethod`) so an unrecognized name still produces a valid
    /// envelope — the dispatcher then replies with an `unknownMethod` error
    /// carrying this `requestId`, instead of failing to decode and silently
    /// dropping the call (which would hang the bundle's pending Promise).
    let name: String
    let requestId: String
    let payload: [String: AnyJSONValue]?

    /// The recognized method, or `nil` when `name` is outside the allowlist.
    /// `nil` is handled at dispatch as an `unknownMethod` error.
    var method: BridgeMethod? { BridgeMethod(rawValue: name) }
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
        /// Bundle called requestPurchase with a productId the App Store
        /// doesn't know about (revoked, not approved, wrong storefront).
        case productUnavailable
        /// Bundle requested data the SDK couldn't resolve from its cache.
        case messageDataUnavailable
        /// Bundle passed a malformed payload (missing productId, malformed
        /// promotional offer fields, etc.).
        case invalidPayload
        /// SDK exceeded the bridge call timeout.
        case timeout
        /// Generic StoreKit / billing failure — used as a catch-all when
        /// no more specific code applies. Inspect `message` for detail.
        case purchaseFailed
        /// `openManageSubscription` / `openDeepLink` URL couldn't be opened.
        case urlOpenFailed
        /// `apiFetch` couldn't complete the round-trip: the supplied path was
        /// rejected (absolute URL / wrong origin → `invalidPayload` instead)
        /// or the request failed at the transport layer (offline, DNS, TLS).
        /// NOTE: HTTP responses — including 4xx / 5xx — are NOT errors here.
        /// They resolve successfully with `ok:false` so the page can read
        /// `status` + `body`.
        case apiRequestFailed

        // MARK: Purchase-specific (StoreKit 2)

        /// Device-level "purchases are not allowed" (Screen Time / parental
        /// controls / managed device).
        case purchaseNotAllowed
        /// The user is not eligible for the promotional offer (already
        /// used it, not in the eligible group, etc.). Bundle should hide
        /// or rebrand the offer surface.
        case ineligibleForOffer
        /// Server-supplied promotional offer parameters were rejected by
        /// StoreKit — bad signature, wrong key id, malformed nonce. The
        /// Galva backend signed something the App Store wouldn't accept.
        case invalidOffer
        /// StoreKit returned an unverified transaction — App Store
        /// signature didn't validate against the device's trust roots.
        case verificationFailed
        /// Generic network / transport problem talking to the App Store.
        case networkError
        /// Product is not sold in the user's current storefront.
        case notAvailableInStorefront
    }
}

/// Strict allowlist of native bridge methods. A name outside this set
/// resolves to `BridgeRequest.method == nil` and is answered with an
/// `unknownMethod` error rather than dispatched — so an out-of-date or
/// malicious bundle can probe but never invoke an unknown surface, while
/// still getting a clean Promise rejection (with its `requestId`).
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
    /// Proxy an authenticated HTTP request to the Galva API. The bundle
    /// supplies a relative `path` only; the SDK prepends the API base URL
    /// and injects the API key. See `NativeBridge.handleAPIFetch`.
    case apiFetch
    /// Present a system `UIAlertController`. Resolves with the id of the
    /// action the user tapped. See `NativeBridge.handleShowAlert`.
    case showAlert
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
    /// Apple App Store storefront country code (ISO 3166-1 alpha-3, e.g.
    /// `"USA"`, `"GBR"`, `"JPN"`). Read from `StoreKit.Storefront.current`.
    /// Used by the bundle to pick storefront-specific copy (currency
    /// suffix conventions, regional offer fallbacks) without a separate
    /// StoreKit round-trip. `nil` when StoreKit isn't reachable (e.g.
    /// device hasn't signed into the App Store) — the bundle falls back
    /// to the `locale` region in that case.
    let storefrontCountryCode: String?
    /// The SDK-managed StoreKit `appAccountToken` (UUID string) for the
    /// current identity: the developer override from
    /// `AppUser.identify(userId:appAccountToken:)` when set, otherwise the
    /// `anonymousId` rendered as a UUID. The bundle attaches this to its own
    /// purchase / attribution calls so a bundle-initiated purchase reconciles
    /// to the same account as a Galva-initiated one. Always populated today;
    /// typed optional to match the other nullable fields and stay
    /// forward-compatible.
    let appAccountToken: String?

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

// MARK: - apiFetch result (returned by `apiFetch`)

/// Bridge response body for `galva.apiFetch(...)`. Mirrors the `fetch`-style
/// shape the hosted page expects: ANY completed HTTP round-trip (including
/// 4xx / 5xx) resolves with this object so the page can read `status` +
/// `body`. Only transport / validation failures reject with a `BridgeError`.
///
/// The SDK encodes this struct straight to JSON (no hand-built
/// `[String: AnyJSONValue]`), so the wire keys are exactly the stored
/// property names — do NOT rename without coordinating a
/// `bridgeProtocolVersion` bump.
struct BridgeAPIFetchResult: Sendable, Hashable, Codable {
    /// HTTP status code (e.g. `200`, `404`).
    let status: Int
    /// Convenience flag — true when `status` is in `200..<300`.
    let ok: Bool
    /// Response headers with lowercased field names.
    let headers: [String: String]
    /// The response payload, shaped per `bodyType`: a parsed JSON value, a
    /// decoded UTF-8 string, or a base64 string of the raw bytes.
    let body: AnyJSONValue
    /// Tells the page how to read `body`.
    let bodyType: BodyType

    enum BodyType: String, Sendable, Hashable, Codable {
        /// `body` is the parsed JSON value of the response.
        case json
        /// `body` is the response decoded as a UTF-8 string.
        case text
        /// `body` is a base64 string of non-UTF-8 (binary) bytes.
        case base64
    }
}

// MARK: - showAlert result (returned by `showAlert`)

/// Bridge response body for `galva.showAlert(...)` — the id of the action
/// the user tapped (from the `actions[].id` values the bundle supplied).
/// The SDK encodes this struct straight to JSON, so the wire key is exactly
/// `actionId`.
struct BridgeAlertResult: Sendable, Hashable, Codable {
    let actionId: String
}
