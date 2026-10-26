//
//  InAppMessageStreamHeldMessageTests.swift
//  GalvaTests
//
//  A message published while nobody is subscribed is held — newest wins —
//  and handed to the next subscriber, once. In `.manual` mode this is what
//  lets an app's loop that starts a moment after launch still get the
//  cold-start message. A subscriber that went away before registering
//  doesn't take it.
//

import Foundation
@testable import Galva
import XCTest

@MainActor
final class InAppMessageStreamHeldMessageTests: XCTestCase {

    private func message(_ id: String) -> InAppMessages.Message {
        InAppMessages.Message(id: id, workflowType: .trialRescue, createdAt: Date())
    }

    /// Let `makeStream()`'s main-actor registration hop run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Wait without suspending, so the main actor can't run anything meanwhile.
    private nonisolated static func block(on semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// First message `stream` delivers, or `nil` if none arrives within
    /// about 300ms.
    private func firstMessage(of stream: AsyncStream<InAppMessages.Message>) async -> InAppMessages.Message? {
        let reader = Task { @MainActor () -> InAppMessages.Message? in
            for await message in stream { return message }
            return nil
        }
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            reader.cancel()
        }
        let result = await reader.value
        timeout.cancel()
        return result
    }

    func test_messageWithNoSubscriber_reachesTheNextSubscriber() async {
        let stream = InAppMessageStream()
        stream.yield(message("a"))
        XCTAssertEqual(stream.heldMessage?.id, "a")

        let received = await firstMessage(of: stream.makeStream())

        XCTAssertEqual(received?.id, "a")
        XCTAssertNil(stream.heldMessage)
    }

    func test_heldMessage_isHandedOverOnlyOnce() async {
        let stream = InAppMessageStream()
        stream.yield(message("a"))

        let first = await firstMessage(of: stream.makeStream())
        let second = await firstMessage(of: stream.makeStream())

        XCTAssertEqual(first?.id, "a")
        XCTAssertNil(second, "a later subscriber must not get the message again")
    }

    func test_newestHeldMessageWins() async {
        let stream = InAppMessageStream()
        stream.yield(message("older"))
        stream.yield(message("newer"))

        let received = await firstMessage(of: stream.makeStream())

        XCTAssertEqual(received?.id, "newer")
    }

    func test_messageDeliveredToASubscriber_isNotHeld() async {
        let stream = InAppMessageStream()
        let live = stream.makeStream()
        await settle()

        stream.yield(message("a"))

        XCTAssertNil(stream.heldMessage)
        let received = await firstMessage(of: live)
        XCTAssertEqual(received?.id, "a")
    }

    func test_subscriberGoneBeforeRegistering_leavesTheHeldMessage() async {
        let stream = InAppMessageStream()
        stream.yield(message("a"))

        // End a subscriber's iteration before its main-actor registration
        // runs: the test keeps the main actor busy until the iteration is over.
        let gone = stream.makeStream()
        let ended = DispatchSemaphore(value: 0)
        let iteration = Task.detached {
            for await _ in gone {}
            ended.signal()
        }
        iteration.cancel()
        Self.block(on: ended)
        await settle()

        XCTAssertEqual(stream.heldMessage?.id, "a",
                       "a subscriber that already went away must not take the held message")
        let received = await firstMessage(of: stream.makeStream())
        XCTAssertEqual(received?.id, "a")
    }

    func test_discardHeldMessage_dropsIt() async {
        let stream = InAppMessageStream()
        stream.yield(message("a"))

        stream.discardHeldMessage()

        XCTAssertNil(stream.heldMessage)
        let received = await firstMessage(of: stream.makeStream())
        XCTAssertNil(received)
    }
}
