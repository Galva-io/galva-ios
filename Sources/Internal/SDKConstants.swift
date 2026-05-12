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
    static let libraryName = "swift"

    /// Value for the `x-sdk-version` header. Format: `swift/X.Y.Z`, max 20 chars.
    static let sdkVersionHeader: String = {
        let raw = "swift/\(version)"
        return String(raw.prefix(20))
    }()

    /// Default Galva API base URL.
    static let defaultBaseURL = URL(string: "https://api.galva.dev")!

    /// Batch endpoint path.
    static let batchCollectPath = "/identities/batchCollect"

    /// Max messages per batch per OpenAPI spec.
    static let maxBatchSize = 100

    /// Default batching window before forced flush.
    static let defaultFlushInterval: TimeInterval = 5
    static let defaultFlushAtCount: Int = 50
}
