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

    func test_sessionStart_deriveFromSnapshot_matchingMessageContext() {
        // `os_version` must come from the captured snapshot
        // (UIDevice.systemVersion shape, e.g. "17.0") — NOT from
        // `ProcessInfo.operatingSystemVersionString` ("Version 17.0 (Build …)").
        let provider = ContextProvider(snapshot: DeviceSnapshot(osVersion: "17.0"))
        let event = provider.sessionStartEvent()
        let ctx = provider.currentContext()

        XCTAssertEqual(event.osVersion, "17.0")

        // Every property mirrors the matching field on the context the SAME
        // provider would stamp onto the message — one source of truth.
        XCTAssertEqual(event.osVersion,    ctx.os?.version ?? "")
        XCTAssertEqual(event.deviceLocale, ctx.locale ?? "")
        XCTAssertEqual(event.appVersion,   ctx.app?.version ?? "")
        XCTAssertEqual(event.sdkVersion,   ctx.library?.version ?? "")
    }

    func test_sessionStart_sdkVersion_matchesConstants() {
        XCTAssertEqual(ContextProvider().sessionStartEvent().sdkVersion, SDKConstants.version)
    }

    func test_sessionStart_attributesOmitDeviceCountry() {
        // device_country is derived server-side from the request IP and must
        // never appear on the wire.
        let attributes = ContextProvider(snapshot: DeviceSnapshot(osVersion: "17.0"))
            .sessionStartEvent().attributes
        XCTAssertNil(attributes?["device_country"])
        XCTAssertEqual(Set((attributes ?? [:]).keys),
                       ["device_locale", "os_version", "app_version", "sdk_version"])
    }

    func test_sessionStart_emptySnapshot_osVersionFallsBackToEmptyString() {
        // With no captured snapshot, os_version falls back to "" rather than
        // dropping the field — keeps the event shape stable.
        XCTAssertEqual(ContextProvider().sessionStartEvent().osVersion, "")
    }
}
