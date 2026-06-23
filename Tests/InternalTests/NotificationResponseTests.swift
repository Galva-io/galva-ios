//
//  NotificationResponseTests.swift
//  GalvaTests
//
//  Covers the notification-response forwarder's host-testable core:
//    • isFromGalva — the `"sender":"galva"` marker gate.
//    • attributes — flatten userInfo + `id` (notification id wins on collision).
//    • end-to-end track round-trip (helper attributes → coercion → SDKCore.track
//      → queued `.track` message) via SDKHarness.
//
//  The gated `Galva.userNotificationCenter(_:didReceive:)` wrapper itself can't
//  be unit-tested — `UNNotificationResponse` has no public initializer — so it's
//  a thin map over these helpers (same approach as the `scene(_:openURLContexts:)`
//  deep-link mirror).
//

import Foundation
@testable import Galva
import XCTest

final class NotificationResponseTests: XCTestCase {

    // MARK: - isFromGalva

    func test_isFromGalva_trueForMarker_caseInsensitive() {
        XCTAssertTrue(NotificationResponse.isFromGalva(["sender": "galva"]))
        XCTAssertTrue(NotificationResponse.isFromGalva(["sender": "Galva", "aps": ["alert": "hi"]]))
    }

    func test_isFromGalva_falseWhenMissingOrOther() {
        XCTAssertFalse(NotificationResponse.isFromGalva([:]))
        XCTAssertFalse(NotificationResponse.isFromGalva(["sender": "acme"]))
        XCTAssertFalse(NotificationResponse.isFromGalva(["aps": ["alert": "hi"]]))
        XCTAssertFalse(NotificationResponse.isFromGalva(["sender": 1]), "non-string sender is not a match")
    }

    // MARK: - attributes

    func test_attributes_flattensUserInfo_andIncludesId() {
        let attrs = NotificationResponse.attributes(
            id: "notif-1",
            userInfo: ["sender": "galva", "campaignId": 42, "aps": ["alert": "Hi"]]
        )
        XCTAssertEqual(attrs["id"] as? String, "notif-1")
        XCTAssertEqual(attrs["sender"] as? String, "galva")
        XCTAssertEqual(attrs["campaignId"] as? Int, 42)
        XCTAssertNotNil(attrs["aps"], "nested aps body is carried through")
    }

    func test_attributes_notificationIdWinsOverUserInfoId() {
        let attrs = NotificationResponse.attributes(id: "notif-1", userInfo: ["id": "from-body"])
        XCTAssertEqual(attrs["id"] as? String, "notif-1")
    }

    func test_attributes_dropsNonStringKeys() {
        let attrs = NotificationResponse.attributes(id: "n", userInfo: [42: "x", "ok": "y"])
        XCTAssertEqual(attrs["ok"] as? String, "y")
        XCTAssertEqual(attrs["id"] as? String, "n")
        XCTAssertEqual(attrs.count, 2, "the non-string (42) key is dropped; only 'ok' + 'id' remain")
    }
}

// MARK: - End-to-end track round-trip

@GalvaActor
final class NotificationResponseTrackTests: XCTestCase {

    func test_tappedEvent_flowsThroughToQueuedTrackMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // Exactly what the forwarder does after unwrapping the response: build
        // the attributes (id + body) and track the event dynamically.
        await harness.consumer.reset()
        await harness.core.track(
            event: NotificationEvent.tapped,
            properties: AnyJSONValue.coercing(dictionary: NotificationResponse.attributes(
                id: "notif-1",
                userInfo: ["sender": "galva", "campaignId": 42, "aps": ["alert": "Hi"]]
            ))
        )

        guard case .track(let event, let props, _, _) = await harness.consumer.allMessages.first?.body else {
            return XCTFail("expected a .track message")
        }
        XCTAssertEqual(event, "$gv_notification_tapped")
        XCTAssertEqual(props?["id"], .string("notif-1"))
        XCTAssertEqual(props?["campaignId"], .int(42))
        XCTAssertEqual(props?["sender"], .string("galva"))
        if case .object(let aps)? = props?["aps"] {
            XCTAssertEqual(aps["alert"], .string("Hi"))
        } else {
            XCTFail("nested aps object should be preserved")
        }
    }
}
