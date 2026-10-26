//
//  NamespacedNamesTests.swift
//  GalvaTests
//
//  An app with its own `AppUser`, `AppEvents` or `InAppMessages` type
//  reaches the SDK's through `Galva.AppUser`, `Galva.AppEvents` and
//  `Galva.InAppMessages`. `ShadowingApp` plays that app: inside it the plain
//  names mean its own types, so this file only compiles if the aliases
//  exist and name the SDK's types.
//

import Foundation
@testable import Galva
import XCTest

/// An app whose own types shadow the SDK's top-level names.
private enum ShadowingApp {
    struct AppUser {}
    struct AppEvents {}
    struct InAppMessages {}

    static var sdkAppUser: Any.Type { Galva.AppUser.self }
    static var sdkAppEvents: Any.Type { Galva.AppEvents.self }
    static var sdkMessage: Any.Type { Galva.InAppMessages.Message.self }

    /// The calls the README shows, written as such an app would. Compiled,
    /// never run.
    @MainActor
    static func integrate() {
        Galva.AppUser.identify(userId: "user_42")
        Galva.AppEvents.track("onboarding_completed")
        _ = Galva.InAppMessages.messages
    }
}

final class NamespacedNamesTests: XCTestCase {

    func test_namespacedNames_areTheSDKsTypes() {
        XCTAssertTrue(ShadowingApp.sdkAppUser == AppUser.self)
        XCTAssertTrue(ShadowingApp.sdkAppEvents == AppEvents.self)
        XCTAssertTrue(ShadowingApp.sdkMessage == InAppMessages.Message.self)
    }

    func test_shadowingAppTypes_areTheApps() {
        XCTAssertFalse(ShadowingApp.AppUser.self == AppUser.self)
    }
}
