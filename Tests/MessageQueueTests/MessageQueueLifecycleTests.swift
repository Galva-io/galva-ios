//
//  MessageQueueLifecycleTests.swift
//  GalvaTests
//
//  Covers start / stop / clear semantics:
//    • startRunloop is idempotent — double-call is a no-op.
//    • stop halts processing but does not drop persisted messages.
//    • emit-after-stop persists; messages are picked up on next start.
//    • clearQueue purges storage atomically.
//

import Foundation
@testable import Galva
import XCTest

final class MessageQueueLifecycleTests: XCTestCase {

    func test_startRunloop_calledTwice_isIdempotent() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(consumer: consumer, storage: TestStorage.memory())

        await queue.startRunloop()
        await queue.startRunloop() // second call should be a no-op

        await queue.emit(.makeTrack(event: "double-start"))
        await waitForMessages(consumer, count: 1)
        let count = await consumer.callCount
        XCTAssertEqual(count, 1)

        await queue.stop()
    }

    func test_emitAfterStop_persistsButDoesNotConsume() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(consumer: consumer, storage: storage)
        await queue.startRunloop()
        await queue.stop()

        for msg in Message.sequence(prefix: "post-stop", count: 4) {
            await queue.emit(msg)
        }

        try? await Task.sleep(nanoseconds: 200_000_000) // grace window
        let callCount = await consumer.callCount
        XCTAssertEqual(callCount, 0, "Stopped queue must not consume")
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 4)
    }

    func test_emitAfterStop_thenRestart_drainsPendingMessages() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(consumer: consumer, storage: storage)
        await queue.startRunloop()
        await queue.stop()

        for msg in Message.sequence(prefix: "queued", count: 3) {
            await queue.emit(msg)
        }

        await queue.startRunloop()
        await waitForMessages(consumer, count: 3)
        let events = await consumer.consumedEvents
        XCTAssertEqual(events, ["queued-000", "queued-001", "queued-002"])

        await queue.stop()
    }

    func test_clearQueue_purgesStorage() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(consumer: consumer, storage: storage)
        await queue.startRunloop()
        await queue.stop()

        for msg in Message.sequence(prefix: "wipe", count: 5) {
            await queue.emit(msg)
        }
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 5)

        try await queue.clearQueue()
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0)
    }

    func test_size_reflectsCurrentBacklog() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(consumer: consumer, storage: storage)
        await queue.startRunloop()
        await queue.stop() // stop before emitting so we can observe size

        await XCTAsyncAssertEqual(try await queue.size, 0)
        await queue.emit(.makeTrack(event: "a"))
        await XCTAsyncAssertEqual(try await queue.size, 1)
        await queue.emit(.makeTrack(event: "b"))
        await XCTAsyncAssertEqual(try await queue.size, 2)

        try await queue.clearQueue()
        await XCTAsyncAssertEqual(try await queue.size, 0)
    }
}
