//
//  BuiltInEventsTests.swift
//  GalvaTests
//
//  The centralized built-in events. `SessionStartEvent` has predictable
//  properties, so they're required typed init params that map to fixed wire
//  keys — you can't construct it with a missing/mistyped property. The
//  notification events carry an arbitrary JSON body, so only their wire names
//  are centralized (tracked dynamically; covered by NotificationResponseTests).
//

import Foundation
@testable import Galva
import XCTest

final class BuiltInEventsTests: XCTestCase {

    func test_sessionStart_nameAndTypedAttributes() {
        let event = SessionStartEvent(
            deviceLocale: "en_US",
            osVersion: "18.0",
            appVersion: "1.2.3",
            sdkVersion: "1.0.0"
        )
        XCTAssertEqual(event.eventName, "session_start")
        let attrs = event.attributes
        XCTAssertEqual(attrs?["device_locale"] as? String, "en_US")
        XCTAssertEqual(attrs?["os_version"] as? String, "18.0")
        XCTAssertEqual(attrs?["app_version"] as? String, "1.2.3")
        XCTAssertEqual(attrs?["sdk_version"] as? String, "1.0.0")
    }

    func test_notificationEvent_wireNames() {
        XCTAssertEqual(NotificationEvent.tapped, "$gv_notification_tapped")
        XCTAssertEqual(NotificationEvent.dismissed, "$gv_notification_dismissed")
    }
}
