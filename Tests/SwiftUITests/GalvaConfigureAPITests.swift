//
//  GalvaConfigureAPITests.swift
//  GalvaTests
//
//  Surface-level compile + identity check for the `.galvaConfigure(...)`
//  SwiftUI modifier. Pins the API shape: the modifier exists on `View`,
//  returns a `View` (chainable), and accepts the full parameter set mirroring
//  `Galva.configure(...)`. Constructing the modified view does NOT run
//  configuration (that only happens on `onAppear`), so the test has no side
//  effects on the SDK singleton.
//
//  Gated on `canImport(SwiftUI)` only (not WebKit/UIKit) — `.galvaConfigure`
//  is cross-platform, unlike the in-app-message modifiers.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import Galva
import XCTest

#if canImport(SwiftUI)

@MainActor
final class GalvaConfigureAPITests: XCTestCase {

    func test_galvaConfigure_minimal_exists() {
        assertIsView(Text("anything").galvaConfigure(apiKey: "pk_test"))
    }

    func test_galvaConfigure_acceptsAllParameters() {
        assertIsView(
            Text("anything").galvaConfigure(
                apiKey: "pk_test",
                environment: .development,
                autoTrackCategories: [.lifecycle],
                logLevel: .debug,
                logger: nil
            )
        )
    }

    /// Generic constraint forces the argument to conform to `View`. If the
    /// modifier is renamed / removed / changes return type, this stops
    /// compiling — the regression signal we want.
    private func assertIsView<V: View>(_ view: V) {
        _ = view
    }
}

#endif // canImport(SwiftUI)
