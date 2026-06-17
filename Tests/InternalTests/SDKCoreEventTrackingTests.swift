//
//  SDKCoreEventTrackingTests.swift
//  GalvaTests
//
//  Covers SDKCore.track:
//    • Emits a `.track` Message with the right event name
//    • Forwards properties unchanged
//    • Inherits current identity (anonymous + identified)
//    • Doesn't auto-attach trait keys to track messages (those belong on
//      identify, not track)
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class SDKCoreEventTrackingTests: XCTestCase {

    func test_track_emitsTrackMessageWithEventName() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.track(event: "AddHabitButtonTapped", properties: nil)

        let messages = await harness.consumer.allMessages
        XCTAssertEqual(messages.count, 1)
        guard case .track(let event, let props, _, _) = messages[0].body else {
            return XCTFail("Expected .track body")
        }
        XCTAssertEqual(event, "AddHabitButtonTapped")
        XCTAssertNil(props)
    }

    func test_track_forwardsPropertiesUnchanged() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        let props: [String: AnyJSONValue] = [
            "sku": .string("pro_yearly"),
            "price": .double(9.99),
            "count": .int(3),
        ]
        await harness.core.track(event: "Purchase", properties: props)

        let messages = await harness.consumer.allMessages
        guard case .track(_, let received, _, _) = messages[0].body else {
            return XCTFail("Expected .track body")
        }
        XCTAssertEqual(received?["sku"], .string("pro_yearly"))
        XCTAssertEqual(received?["price"], .double(9.99))
        XCTAssertEqual(received?["count"], .int(3))
    }

    func test_track_carriesCurrentAnonymousId_whenNotIdentified() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.track(event: "e", properties: nil)

        guard let msg = await harness.consumer.allMessages.first else {
            return XCTFail("No track message emitted")
        }
        XCTAssertEqual(msg.anonymousId, harness.identity.anonymousId)
        XCTAssertNil(msg.endUserId)
    }

    func test_track_carriesEndUserId_afterIdentify() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "user_99", appAccountToken: nil, traits: nil)
        await harness.consumer.reset()
        await harness.core.track(event: "e", properties: nil)

        guard let msg = await harness.consumer.allMessages.first else {
            return XCTFail("No track message emitted")
        }
        XCTAssertEqual(msg.endUserId, "user_99")
        XCTAssertEqual(msg.anonymousId, harness.identity.anonymousId)
    }

    func test_track_doesNotAttachIdentifyTraits() async {
        // The auto-attach behaviour ($gv_timezone etc.) belongs to identify
        // messages, not track. A track message should carry only the
        // caller-supplied properties.
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.track(event: "e", properties: ["foo": .string("bar")])

        guard case .track(_, let props, _, _) =
                await harness.consumer.allMessages.first?.body
        else {
            return XCTFail("Expected .track body")
        }
        XCTAssertEqual(props?["foo"], .string("bar"))
        XCTAssertNil(props?[BuiltInTraitKey.timezone], "Device traits are identify-only, not track")
        XCTAssertNil(props?[BuiltInTraitKey.languageCode], "Device traits are identify-only, not track")
    }
}
