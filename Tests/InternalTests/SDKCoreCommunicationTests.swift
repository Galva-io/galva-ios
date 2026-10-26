//
//  SDKCoreCommunicationTests.swift
//  GalvaTests
//
//  Covers SDKCore's communication endpoint surface:
//    • createEndpoint(push) → emits create-communication-endpoint
//
//  Wire-format details (kebab-case channel type) are covered by
//  CommunicationEndpointTests; here we verify SDKCore wires the right
//  payload into the right Message body.
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class SDKCoreCommunicationTests: XCTestCase {

    // MARK: - createEndpoint

    func test_createEndpoint_pushApns_emitsMessage() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.createEndpoint(.pushNotification(platform: .apns, token: "TOK"))

        let endpoint = await harness.consumer.allMessages.first?.communicationEndpoint
        XCTAssertEqual(endpoint, .pushNotification(platform: .apns, token: "TOK"))
    }

    // MARK: - Identity carry-through

    func test_communicationMessage_carriesCurrentEndUserId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "u_777", appAccountToken: nil, traits: nil)
        await harness.consumer.reset()
        await harness.core.createEndpoint(.pushNotification(platform: .apns, token: "TOK"))

        guard let msg = await harness.consumer.allMessages.first else {
            return XCTFail("No message emitted")
        }
        XCTAssertEqual(msg.endUserId, "u_777")
        XCTAssertEqual(msg.anonymousId, harness.identity.anonymousId)
    }
}
