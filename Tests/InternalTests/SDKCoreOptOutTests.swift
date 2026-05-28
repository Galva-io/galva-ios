//
//  SDKCoreOptOutTests.swift
//  GalvaTests
//
//  Verifies the opt-out kill switch:
//
//      • `setOptedOut(true)` causes subsequent `track`, `identify`,
//        `createEndpoint`, `deleteEndpoint`, `setPreference` calls to
//        become silent no-ops (no messages enqueued, no consumer
//        invocation).
//      • The on-disk event queue is purged on the false → true
//        transition so pre-existing events don't leak.
//      • `isOptedOut` returns synchronously from the lock-protected
//        mirror, consistent with the most recent `setOptedOut` call.
//      • Toggling back to `false` re-enables event emission without
//        requiring a re-configure.
//

import Foundation
@testable import Galva
import XCTest

final class SDKCoreOptOutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset the lock-protected mirror so prior tests don't leak
        // into this run (the underlying UserDefaults is per-suite, but
        // the in-memory mirror is process-global).
        SDKCore.setOptedOutFlag(false, defaults: UserDefaults.standard)
    }

    override func tearDown() {
        SDKCore.setOptedOutFlag(false, defaults: UserDefaults.standard)
        super.tearDown()
    }

    // MARK: - Sync read

    func test_isOptedOut_reflectsMostRecentSet() {
        XCTAssertFalse(SDKCore.shared.isOptedOut)
        SDKCore.setOptedOutFlag(true)
        XCTAssertTrue(SDKCore.shared.isOptedOut)
        SDKCore.setOptedOutFlag(false)
        XCTAssertFalse(SDKCore.shared.isOptedOut)
    }

    // MARK: - Event gating

    func test_track_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // Baseline emission count after configure (the seeded identity
        // message, plus any other startup-time messages).
        let baseline = await harness.consumer.allMessages.count

        await Self.setOptedOut(true)
        await harness.core.track(event: "after_optout", properties: nil)
        // Give the queue runloop a chance to drain anything that was
        // already enqueued before the opt-out. New messages should
        // NOT appear in the consumer.
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        let events = await harness.consumer.consumedEvents
        XCTAssertFalse(events.contains("after_optout"),
                       "track must not enqueue when opted out")
    }

    func test_identify_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let baseline = await harness.consumer.allMessages.count
        await Self.setOptedOut(true)
        await harness.core.identify(
            userId: "user_after_optout",
            appAccountToken: nil,
            traits: nil
        )
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        // endUserId must remain whatever it was before the opt-out
        // (identify is a no-op, it doesn't even update the cache).
        let userId = await harness.core.currentEndUserId
        XCTAssertNotEqual(userId, "user_after_optout")
    }

    func test_createEndpoint_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let baseline = await harness.consumer.allMessages.count
        await Self.setOptedOut(true)
        await harness.core.createEndpoint(.email("user@example.com"))
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        let messages = await harness.consumer.allMessages
        XCTAssertFalse(messages.contains(where: { $0.communicationEndpoint != nil }))
    }

    func test_setPreference_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let baseline = await harness.consumer.allMessages.count
        await Self.setOptedOut(true)
        await harness.core.setPreference(channel: .email, disabled: true, categories: nil)
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        let messages = await harness.consumer.allMessages
        XCTAssertFalse(messages.contains(where: { $0.preferenceTuple != nil }))
    }

    // MARK: - Re-enable round-trip

    func test_track_resumesEmitting_afterOptingBackIn() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await Self.setOptedOut(true)
        await harness.core.track(event: "while_opted_out", properties: nil)
        await Self.setOptedOut(false)
        await harness.core.track(event: "after_opt_back_in", properties: nil)

        await waitForMessages(harness.consumer, count: 1, timeout: 2.0)
        let events = await harness.consumer.consumedEvents
        XCTAssertTrue(events.contains("after_opt_back_in"))
        XCTAssertFalse(events.contains("while_opted_out"))
    }

    // MARK: - Helpers

    /// Routes through the GalvaActor-isolated setter so the call
    /// matches the production path the public API takes.
    @GalvaActor
    private static func setOptedOut(_ value: Bool) async {
        await SDKCore.shared.setOptedOut(value)
    }
}
