//
//  SDKCore+Testing.swift
//  Galva
//
//  The one test seam that has to live in `Sources/`: `SDKCore.shared` reads
//  `SDKCoreTestBinding`, so it must compile into the SDK. The helpers that
//  configure a test core (`configureForTesting` and friends) live with the
//  tests, in Tests/InternalTests/SDKCoreTestSupport.swift. They touch
//  internal members and the `@_spi(GalvaIntegration)` logger helpers, so
//  that file imports `@_spi(GalvaIntegration) @testable import Galva`.
//
//  Not part of the SDK's public API, and never bound in production.
//

import Foundation

/// Points `SDKCore.shared` — and so every public entry point — at a test's
/// own core: `SDKCoreTestBinding.$core.withValue(harness.core) { … }`.
/// Calls made inside, and tasks they start, reach that core instead of the
/// production singleton.
enum SDKCoreTestBinding {
    @TaskLocal static var core: SDKCore?
}
