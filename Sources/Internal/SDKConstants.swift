//
//  SDKConstants.swift
//  Galva
//
//  Compile-time constants. Bump `version` on every release.
//

import Foundation

enum SDKConstants {
    /// Public SDK version. Bump on every release.
    static let version = "1.0.0"

    /// Default library name (native core). Wrapper SDKs override the reported
    /// identity via `Galva.configure(wrapper:)` — see `SDKIdentity`.
    static let libraryName = "ios"

    // MARK: - Per-environment URLs
    //
    // Exposed as `static let` so `Galva.Environment` can map each case to
    // its concrete URL without rebuilding URL(string:) on every read. The
    // `!` is safe — URL(string:) cannot fail on a build-time literal that
    // we've verified.

    /// Production Galva API.
    static let productionAPIBaseURL = URL(string: "https://api.galva.io")! // galva-lint:disable reason="build-time literal"
    /// Development / staging Galva API.
    static let developmentAPIBaseURL = URL(string: "https://api.galva.dev")! // galva-lint:disable reason="build-time literal"

    /// Production CDN hosting WebView HTML bundles. Bundles are immutable
    /// per version; the SDK downloads `<bundleCDN>/<version>.html` on
    /// first encounter and caches under Application Support / Caches.
    static let productionWebviewBundleCDN = URL(string: "https://webview.galva.io")! // galva-lint:disable reason="build-time literal"
    /// Development / staging WebView bundle CDN.
    static let developmentWebviewBundleCDN = URL(string: "https://webview.galva.dev")! // galva-lint:disable reason="build-time literal"

    /// Native ↔ hosted-page bridge contract version. Reported to the server
    /// on /sdk/initialize and to the hosted page via `galva.getPageContext`.
    /// Bump on any breaking change to the bridge wire protocol.
    static let bridgeProtocolVersion = "1.0"

    /// Default WebView bundle version the SDK falls back to when neither
    /// `/sdk/initialize` nor a server resolve has pinned one (typical of
    /// truly offline first launches). Build with a version known to be
    /// hosted on every active CDN so the show flow can still load HTML.
    static let fallbackWebviewVersion = "1.0.0"

    // MARK: - Endpoint paths
    //
    // Each path is exposed as either a `static let` (no parameters) or a
    // `static func ...(...) -> String` for parameterized routes. The
    // function form prevents the string-templating bugs that
    // `"/x/{id}/y".replacingOccurrences(of:)` is prone to.

    /// `POST /identities/batchCollect` — event upload batch endpoint.
    static let batchCollectPath = "/identities/batchCollect"

    /// `POST /sdk/initialize` — SDK bootstrap config.
    static let sdkInitializePath = "/sdk/initialize"

    /// `GET /identities/communications` — list pending in-app
    /// communications for the current identity.
    static let communicationListPath = "/identities/communications"

    /// `POST /identities/communications/{messageId}/resolve` — resolve a
    /// single communication to its renderable payload.
    static func communicationResolvePath(messageId: UUID) -> String {
        "/identities/communications/\(messageId.uuidString.lowercased())/resolve"
    }

    /// `POST /v1/transactions/observe` — reports
    /// `(originalTransactionId, userId)` mappings so Galva can join App
    /// Store Server Notifications that arrive without a matching
    /// `appAccountToken` (organic purchases, family-shared transactions,
    /// pre-identify activity). See the Store Notifications docs:
    /// https://docs.galva.io/integrations/store-notifications/
    static let transactionsObservePath = "/v1/transactions/observe"

    /// Build the file URL for a WebView bundle on the supplied CDN. Used
    /// by `WebViewBundleCache` so the path scheme stays in one place.
    static func webviewBundleURL(version: String, cdn: URL) -> URL {
        cdn.appendingPathComponent("\(version).html")
    }

    /// Max messages per batch per OpenAPI spec.
    static let maxBatchSize = 100

    /// Default batching window before forced flush. Server-driven values
    /// from `/sdk/initialize` override these at runtime — these only
    /// apply during the brief window between configure() and the first
    /// successful init response.
    static let defaultFlushInterval: TimeInterval = 5
    static let defaultFlushAtCount: Int = 50

    /// Timeout (seconds) used by all non-batch RPC calls (initialize, list,
    /// resolve, bundle download). Short so we fall back to cache quickly
    /// when the network is degraded.
    static let rpcTimeout: TimeInterval = 15

    /// Hard cap on pending messages persisted locally. Protects the host
    /// app from unbounded storage growth when the device is offline for
    /// long stretches. Set conservatively — at ~1 KB per message this is
    /// ~10 MB of disk worst case, matching the design doc target.
    static let defaultMaxStoredMessages: Int = 10_000
}
