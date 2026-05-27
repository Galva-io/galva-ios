//
//  GalvaSwiftUIAPITests.swift
//  GalvaTests
//
//  Surface-level compile + identity check for the SwiftUI integration
//  modifiers. We can't unit-test the actual sheet presentation without
//  ViewInspector or running the app in a UI test target, so these tests
//  pin the *shape* of the API:
//
//      • `.inAppMessageSheet($binding)` exists on `View` and returns a
//        `View` (preserves chaining).
//      • `.autoDisplayInAppMessages()` exists on `View` and returns a
//        `View`.
//
//  If either modifier is renamed / removed / changes return type, the
//  test target fails to build — catches regressions before they ship.
//
//  Implementation note: `let _: some View = …` is rejected by the Swift
//  compiler because `some` requires a *named* property declaration. We
//  route through a generic `assertIsView(_:)` helper instead — its
//  generic constraint (`<V: View>`) enforces the conformance at the call
//  site without naming an opaque return type.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
@testable import Galva
import XCTest

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)

@MainActor
final class GalvaSwiftUIAPITests: XCTestCase {

    func test_inAppMessageSheet_modifier_exists() {
        let binding: Binding<InAppMessages.Message?> = .constant(nil)
        assertIsView(Text("anything").inAppMessageSheet(binding))
    }

    func test_autoDisplayInAppMessages_modifier_exists() {
        assertIsView(Text("anything").autoDisplayInAppMessages())
    }

    func test_inAppMessageSheet_acceptsLiveBinding() {
        // Slightly more realistic — use a regular Binding wrapped over
        // a local state holder so the API works with non-constant
        // bindings (real apps pass `$state` from a `@State`).
        let holder = MessageHolder()
        let binding = Binding<InAppMessages.Message?>(
            get: { holder.message },
            set: { holder.message = $0 }
        )
        assertIsView(Color.clear.inAppMessageSheet(binding))
        XCTAssertNil(holder.message)
    }

    // MARK: - Helpers

    /// Generic constraint forces the argument to conform to `View`. If
    /// either modifier ever stops returning a View (or stops compiling
    /// against this argument shape), this stops compiling — exactly the
    /// regression signal we want.
    private func assertIsView<V: View>(_ view: V) {
        _ = view
    }

    /// Plain holder so the live-binding test can read/write through a
    /// reference. The test never actually presents the sheet, so we
    /// only care that the API accepts the binding.
    @MainActor
    private final class MessageHolder {
        var message: InAppMessages.Message?
    }
}

#endif // canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
