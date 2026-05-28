//
//  ContextProviderTests.swift
//  GalvaTests
//
//  Covers `ContextProvider.sessionProperties()` — the property bag attached
//  to the auto-tracked `session_start` event. The point of routing these
//  through `ContextProvider` (rather than re-reading `ProcessInfo` /
//  `Bundle` / `Locale` independently) is consistency: a session_start's
//  custom properties must agree with the `context` envelope on its own
//  message. These tests pin that contract.
//

import Foundation
@testable import Galva
import XCTest

final class ContextProviderTests: XCTestCase {

    // MARK: - session_start property bag

    func test_sessionProperties_deriveFromSnapshot_matchingMessageContext() {
        // `os_version` must come from the captured snapshot
        // (UIDevice.systemVersion shape, e.g. "17.0") — NOT from
        // `ProcessInfo.operatingSystemVersionString` ("Version 17.0 (Build …)").
        let provider = ContextProvider(snapshot: DeviceSnapshot(osVersion: "17.0"))
        let props = provider.sessionProperties()
        let ctx = provider.currentContext()

        XCTAssertEqual(props["os_version"], .string("17.0"))

        // Every property mirrors the matching field on the context the SAME
        // provider would stamp onto the message — one source of truth.
        XCTAssertEqual(props["os_version"],    .string(ctx.os?.version ?? ""))
        XCTAssertEqual(props["device_locale"], .string(ctx.locale ?? ""))
        XCTAssertEqual(props["app_version"],   .string(ctx.app?.version ?? ""))
        XCTAssertEqual(props["sdk_version"],   .string(ctx.library?.version ?? ""))
    }

    func test_sessionProperties_sdkVersion_matchesConstants() {
        let props = ContextProvider().sessionProperties()
        XCTAssertEqual(props["sdk_version"], .string(SDKConstants.version))
    }

    func test_sessionProperties_omitDeviceCountry() {
        // device_country is derived server-side from the request IP and must
        // never appear on the wire.
        let props = ContextProvider(snapshot: DeviceSnapshot(osVersion: "17.0"))
            .sessionProperties()
        XCTAssertNil(props["device_country"])
        XCTAssertEqual(Set(props.keys),
                       ["device_locale", "os_version", "app_version", "sdk_version"])
    }

    func test_sessionProperties_emptySnapshot_stillEmitsAllKeysAsStrings() {
        // With no captured snapshot, os_version falls back to "" rather than
        // dropping the key — keeps the event shape stable.
        let props = ContextProvider().sessionProperties()
        XCTAssertEqual(props["os_version"], .string(""))
        for key in ["device_locale", "os_version", "app_version", "sdk_version"] {
            guard case .string? = props[key] else {
                return XCTFail("\(key) missing or not a string")
            }
        }
    }
}
