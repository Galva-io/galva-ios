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
    static let defaultBaseURL = URL(string: "https://api.galva.dev")!

    /// Batch endpoint path.
    static let batchCollectPath = "/identities/batchCollect"

    /// Max messages per batch per OpenAPI spec.
    static let maxBatchSize = 100

    /// Default batching window before forced flush.
    static let defaultFlushInterval: TimeInterval = 5
    static let defaultFlushAtCount: Int = 50
}
