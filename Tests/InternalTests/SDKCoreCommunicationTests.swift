//
//  SDKCoreCommunicationTests.swift
//  GalvaTests
//
//  Covers SDKCore's communication endpoint + preference surface:
//    • createEndpoint(email) → emits create-communication-endpoint
//    • createEndpoint(push)  → same with push payload
//    • deleteEndpoint        → emits delete-communication-endpoint
//    • setPreference         → emits set-communication-preference
//
//  Wire-format details (kebab-case channel types, in-app accepted only as
//  a preference channel) are covered by CommunicationEndpointTests; here
//  we verify SDKCore wires the right payloads into the right Message body.
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class SDKCoreCommunicationTests: XCTestCase {

    // MARK: - createEndpoint

    func test_createEndpoint_email_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.createEndpoint(.email("user@example.com"))

        guard let msg = await harness.consumer.allMessages.first,
              case .createCommunicationEndpoint(let endpoint) = msg.body else {
            return XCTFail("Expected createCommunicationEndpoint body")
        }
        XCTAssertEqual(endpoint, .email("user@example.com"))
    }

    func test_createEndpoint_pushApns_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.createEndpoint(.pushNotification(platform: .apns, token: "TOK"))

        let endpoint = await harness.consumer.allMessages.first?.communicationEndpoint
        XCTAssertEqual(endpoint, .pushNotification(platform: .apns, token: "TOK"))
    }

    func test_createEndpoint_pushFcm_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.createEndpoint(.pushNotification(platform: .fcm, token: "FCM"))

        let endpoint = await harness.consumer.allMessages.first?.communicationEndpoint
        XCTAssertEqual(endpoint, .pushNotification(platform: .fcm, token: "FCM"))
    }

    // MARK: - deleteEndpoint

    func test_deleteEndpoint_email_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.deleteEndpoint(.email("gone@x.co"))

        guard let msg = await harness.consumer.allMessages.first,
              case .deleteCommunicationEndpoint(let endpoint) = msg.body else {
            return XCTFail("Expected deleteCommunicationEndpoint body")
        }
        XCTAssertEqual(endpoint, .email("gone@x.co"))
    }

    func test_deleteEndpoint_push_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.deleteEndpoint(.pushNotification(platform: .apns, token: "T"))

        let endpoint = await harness.consumer.allMessages.first?.communicationEndpoint
        XCTAssertEqual(endpoint, .pushNotification(platform: .apns, token: "T"))
    }

    // MARK: - setPreference

    func test_setPreference_disablesChannel_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.setPreference(channel: .email, disabled: true, categories: nil)

        let tuple = await harness.consumer.allMessages.first?.preferenceTuple
        XCTAssertEqual(tuple?.0, .email)
        XCTAssertEqual(tuple?.1, true)
        XCTAssertNil(tuple?.2)
    }

    func test_setPreference_perCategory_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        let categories: [String: Bool] = [
            "payment-recovery": false,
            "winback": true,
        ]
        await harness.core.setPreference(
            channel: .pushNotification,
            disabled: nil,
            categories: categories
        )

        let tuple = await harness.consumer.allMessages.first?.preferenceTuple
        XCTAssertEqual(tuple?.0, .pushNotification)
        XCTAssertNil(tuple?.1)
        XCTAssertEqual(tuple?.2?["payment-recovery"], false)
        XCTAssertEqual(tuple?.2?["winback"], true)
    }

    func test_setPreference_inAppChannel_emitsMessage() async {
        // in-app is the one channel that's valid for set-preference but NOT
        // for create/delete endpoint messages — make sure SDKCore handles it.
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.setPreference(channel: .inApp, disabled: false, categories: nil)

        let tuple = await harness.consumer.allMessages.first?.preferenceTuple
        XCTAssertEqual(tuple?.0, .inApp)
        XCTAssertEqual(tuple?.1, false)
    }

    // MARK: - Identity carry-through

    func test_communicationMessage_carriesCurrentEndUserId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "u_777", appAccountToken: nil, traits: nil)
        await harness.consumer.reset()
        await harness.core.createEndpoint(.email("u@x.co"))

        guard let msg = await harness.consumer.allMessages.first else {
            return XCTFail("No message emitted")
        }
        XCTAssertEqual(msg.endUserId, "u_777")
        XCTAssertEqual(msg.anonymousId, harness.identity.anonymousId)
    }
}
