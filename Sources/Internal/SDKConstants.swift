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

    /// Library name as it appears in the `context.library` field.
    static let libraryName = "ios"

    /// Value for the `x-sdk-version` header. Format: `ios-X.Y.Z`.
    static let sdkVersionHeader: String = "\(libraryName)-\(version)"

    /// Default Galva API base URL.
    static let defaultBaseURL = URL(string: "https://api.galva.dev")! // galva-lint:disable reason="hardcoded build-time constant; URL parser cannot fail on this literal"

    /// CDN that hosts WebView HTML bundles. Bundles are immutable per
    /// version; the SDK downloads `<bundleCDN>/<version>.html` on first
    /// encounter and caches under Application Support / Caches.
    static let webviewBundleCDN = URL(string: "https://webview.galva.io")! // galva-lint:disable reason="hardcoded build-time constant"

    /// Native ↔ hosted-page bridge contract version. Reported to the server
    /// on /sdk/initialize and to the hosted page via `galva.getPageContext`.
    /// Bump on any breaking change to the bridge wire protocol.
    static let bridgeProtocolVersion = "1.0"

    /// Batch endpoint path.
    static let batchCollectPath = "/identities/batchCollect"
    /// SDK initialization endpoint path.
    static let sdkInitializePath = "/sdk/initialize"
    /// Communication list endpoint path.
    static let communicationListPath = "/identities/communications"
    /// Communication resolve endpoint path template — `{id}` is replaced at call time.
    static let communicationResolvePath = "/identities/communications/{id}/resolve"

    /// Max messages per batch per OpenAPI spec.
    static let maxBatchSize = 100

    /// Default batching window before forced flush.
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
