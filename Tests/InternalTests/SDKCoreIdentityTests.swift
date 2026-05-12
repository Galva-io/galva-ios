//
//  SDKCoreIdentityTests.swift
//  GalvaTests
//
//  Covers the identity surface:
//    • identify(userId:) → emits identify, sets cachedEndUserId
//    • identify(traits:) → emits identify, merges built-in traits, caller
//      values win on key collision
//    • identify(appAccountToken:) → adds $gv_appAccountToken trait
//    • logOut() → clears endUserId, rotates anonymousId, re-seeds identify
//    • cachedEndUserId is observable synchronously after the async call
//      returns (the lock-protected mirror is updated before the queue.emit)
//
//  Every test uses a fresh SDKHarness, so identity state never leaks across
//  tests via the production SDKCore.shared singleton.
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class SDKCoreIdentityTests: XCTestCase {

    // MARK: - identify(userId:)

    func test_identify_emitsIdentifyMessage_withUserId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.identify(userId: "user_42", appAccountToken: nil, traits: nil)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        let endUserId = await harness.consumer.allMessages.first?.endUserId
        XCTAssertEqual(endUserId, "user_42")
        XCTAssertNotNil(traits["$gv_timezone"], "Device traits must still be auto-attached")
    }

    func test_identify_updatesCachedEndUserIdSynchronously() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        XCTAssertNil(harness.core.cachedEndUserId)
        await harness.core.identify(userId: "user_synced", appAccountToken: nil, traits: nil)
        XCTAssertEqual(
            harness.core.cachedEndUserId,
            "user_synced",
            "cachedEndUserId must be observable as soon as identify returns"
        )
    }

    // MARK: - identify(traits:)

    func test_identify_mergesCallerTraitsWithBuiltIns() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        let caller: [String: AnyJSONValue] = ["$gv_email": .string("a@b.co")]
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: caller)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        XCTAssertEqual(traits["$gv_email"], .string("a@b.co"))
        XCTAssertNotNil(traits["$gv_timezone"])
        XCTAssertNotNil(traits["$gv_languageCode"])
    }

    func test_identify_callerSuppliedTraitWinsOverAutoAttached() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        let caller: [String: AnyJSONValue] = ["$gv_timezone": .string("Antarctica/South_Pole")]
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: caller)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        XCTAssertEqual(
            traits["$gv_timezone"],
            .string("Antarctica/South_Pole"),
            "Caller-supplied trait must win over auto-attached value"
        )
    }

    func test_identify_appAccountToken_attachedAsTrait() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        await harness.core.identify(userId: "u", appAccountToken: uuid, traits: nil)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        XCTAssertEqual(traits["$gv_appAccountToken"], .string(uuid.uuidString))
    }

    // MARK: - logOut

    func test_logOut_clearsEndUserId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "user_to_logout", appAccountToken: nil, traits: nil)
        XCTAssertEqual(harness.core.cachedEndUserId, "user_to_logout")

        await harness.core.logOut()
        XCTAssertNil(harness.core.cachedEndUserId)
    }

    func test_logOut_rotatesAnonymousId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let before = harness.identity.anonymousId
        await harness.core.logOut()
        let after = harness.identity.anonymousId

        XCTAssertNotEqual(before, after, "logOut should rotate the anonymousId")
    }

    func test_logOut_emitsFreshSeedIdentifyForNewAnonymousUser() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        await harness.core.logOut()

        let messages = await harness.consumer.allMessages
        XCTAssertEqual(messages.count, 1, "logOut should emit a single seed identify")
        guard let first = messages.first, case .identify = first.body else {
            return XCTFail("Expected seed identify")
        }
        XCTAssertNil(first.endUserId)
        XCTAssertEqual(first.anonymousId, harness.identity.anonymousId)
    }

    // MARK: - Identity persistence

    func test_identifyTraitsOnly_doesNotChangeUserId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "stable_user", appAccountToken: nil, traits: nil)
        await harness.consumer.reset()

        // Calling with userId=nil should NOT clear the existing user id.
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: ["custom": .int(1)])

        XCTAssertEqual(harness.core.cachedEndUserId, "stable_user")
        let msg = await harness.consumer.allMessages.first
        XCTAssertEqual(msg?.endUserId, "stable_user")
    }

    // MARK: - Helpers

    /// Pulls the traits dict off the first emitted identify message. Returns
    /// `nil` and fails the test if the queue didn't receive an identify with
    /// non-nil traits.
    private func firstIdentifyTraits(
        in harness: SDKHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [String: AnyJSONValue]? {
        let messages = await harness.consumer.allMessages
        guard let first = messages.first else {
            XCTFail("No message emitted", file: file, line: line)
            return nil
        }
        guard case .identify(let traits) = first.body else {
            XCTFail("Expected .identify, got \(first.body)", file: file, line: line)
            return nil
        }
        guard let traits else {
            XCTFail("Expected non-nil traits", file: file, line: line)
            return nil
        }
        return traits
    }
}
