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

    /// Batch endpoint path.
    static let batchCollectPath = "/identities/batchCollect"

    /// Max messages per batch per OpenAPI spec.
    static let maxBatchSize = 100

    /// Default batching window before forced flush.
    static let defaultFlushInterval: TimeInterval = 5
    static let defaultFlushAtCount: Int = 50

    /// Hard cap on pending messages persisted locally. Protects the host
    /// app from unbounded storage growth when the device is offline for
    /// long stretches. Set conservatively — at ~1 KB per message this is
    /// ~10 MB of disk worst case, matching the design doc target.
    static let defaultMaxStoredMessages: Int = 10_000
}
