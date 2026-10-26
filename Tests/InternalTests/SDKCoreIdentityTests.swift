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
//    • switching users (A → B) drops A's appAccountToken override and
//      in-app state; first login (anonymous → A) keeps both
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
        XCTAssertNotNil(traits[BuiltInTraitKey.timezone], "Device traits must still be auto-attached")
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
        let caller: [String: AnyJSONValue] = [BuiltInTraitKey.email: .string("a@b.co")]
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: caller)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        XCTAssertEqual(traits[BuiltInTraitKey.email], .string("a@b.co"))
        XCTAssertNotNil(traits[BuiltInTraitKey.timezone])
        XCTAssertNotNil(traits[BuiltInTraitKey.languageCode])
    }

    func test_identify_callerSuppliedTraitWinsOverAutoAttached() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        let caller: [String: AnyJSONValue] = [BuiltInTraitKey.timezone: .string("Antarctica/South_Pole")]
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: caller)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        XCTAssertEqual(
            traits[BuiltInTraitKey.timezone],
            .string("Antarctica/South_Pole"),
            "Caller-supplied trait must win over auto-attached value"
        )
    }

    func test_identify_appAccountToken_attachedAsTrait() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.consumer.reset()
        // Letter-bearing UUID so the lowercase wire convention is observable;
        // `UUID.uuidString` returns uppercase by default.
        let uuid = UUID(uuidString: "B1FE821D-5597-4ABC-87B6-1F9647CFFD6E")!
        await harness.core.identify(userId: "u", appAccountToken: uuid, traits: nil)

        guard let traits = await firstIdentifyTraits(in: harness) else { return }
        XCTAssertEqual(traits[BuiltInTraitKey.appAccountToken], .string("b1fe821d-5597-4abc-87b6-1f9647cffd6e"))
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

    // MARK: - Switching users

    func test_switchingUsers_dropsPreviousUsersAppAccountToken() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let tokenA = UUID()

        await harness.core.identify(userId: "user_A", appAccountToken: tokenA, traits: nil)
        await harness.core.identify(userId: "user_B", appAccountToken: nil, traits: nil)

        let generated = UUID(uuidString: harness.identity.anonymousId)
        XCTAssertNil(harness.identity.appAccountToken, "user_A's override must not carry over to user_B")
        XCTAssertEqual(harness.identity.purchaseAttributionToken, generated)
        XCTAssertEqual(harness.core.cachedAppAccountToken, generated, "AppUser.appAccountToken follows")
    }

    func test_switchingUsers_withNewToken_usesIt() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let tokenB = UUID()

        await harness.core.identify(userId: "user_A", appAccountToken: UUID(), traits: nil)
        await harness.core.identify(userId: "user_B", appAccountToken: tokenB, traits: nil)

        XCTAssertEqual(harness.identity.purchaseAttributionToken, tokenB)
        XCTAssertEqual(harness.core.cachedAppAccountToken, tokenB)
    }

    func test_reidentifyingSameUser_keepsToken() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let tokenA = UUID()

        await harness.core.identify(userId: "user_A", appAccountToken: tokenA, traits: nil)
        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)

        XCTAssertEqual(harness.identity.purchaseAttributionToken, tokenA)
        XCTAssertEqual(harness.core.cachedAppAccountToken, tokenA)
    }

    func test_switchingUsers_resetsPreviousUsersInAppState() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let manager = harness.makeInAppMessageManager()
        harness.core.inAppMessageManager = manager
        let stream = harness.core.inAppMessageStream

        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)
        manager.setActiveMessageId("message_for_A")
        await MainActor.run { stream.yield(Self.message("held_for_A")) }
        let anonymousId = harness.identity.anonymousId

        await harness.core.identify(userId: "user_B", appAccountToken: nil, traits: nil)

        XCTAssertFalse(manager.hasPresented(messageId: "message_for_A"), "in-app dedupe is per user")
        XCTAssertNil(manager.activeMessageId)
        let held = await MainActor.run { stream.heldMessage }
        XCTAssertNil(held, "a message held for user_A must not reach user_B")
        XCTAssertEqual(harness.identity.anonymousId, anonymousId, "only logOut rotates the anonymousId")
    }

    func test_firstLogin_keepsInAppState() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let manager = harness.makeInAppMessageManager()
        harness.core.inAppMessageManager = manager
        let stream = harness.core.inAppMessageStream

        manager.setActiveMessageId("shown_while_anonymous")
        await MainActor.run { stream.yield(Self.message("held")) }

        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)

        XCTAssertTrue(manager.hasPresented(messageId: "shown_while_anonymous"))
        let held = await MainActor.run { stream.heldMessage }
        XCTAssertEqual(held?.id, "held", "anonymous → identified is the same person; nothing resets")
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

    private nonisolated static func message(_ id: String) -> InAppMessages.Message {
        InAppMessages.Message(id: id, workflowType: nil, createdAt: Date())
    }
}
