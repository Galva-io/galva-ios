//
//  MessageQueueDurabilityTests.swift
//  GalvaTests
//
//  Covers the durability guarantee that makes this queue useful: messages
//  survive a process restart. We simulate "restart" by recreating the
//  SQLiteMessageStorage against the same on-disk path with a fresh
//  MessageQueue instance and a fresh consumer.
//

import Foundation
@testable import Galva
import XCTest

final class MessageQueueDurabilityTests: XCTestCase {

    func test_messagesSurviveRestart_andAreDeliveredToNewConsumer() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        // Phase 1 — emit then immediately shut down without draining.
        do {
            let consumer = RecordingConsumer()
            let queue = MessageQueue(consumer: consumer, storage: handle.storage)
            await queue.startRunloop()
            await queue.stop()
            for msg in Message.sequence(prefix: "ghost", count: 5) {
                await queue.emit(msg)
            }
            await XCTAsyncAssertEqual(try await queue.size, 5)
        }

        // Phase 2 — new storage instance against the same file, new consumer.
        let revived = try SQLiteMessageStorage(dbPath: handle.path)
        handle.storage = revived

        let consumer = RecordingConsumer()
        let queue = MessageQueue(consumer: consumer, storage: revived)
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await waitForMessages(consumer, count: 5, timeout: 5.0)
        let events = await consumer.consumedEvents
        XCTAssertEqual(events, (0 ..< 5).map { "ghost-\(String(format: "%03d", $0))" })
        await XCTAsyncAssertEqual(try await revived.getQueueSize(), 0)
    }

    func test_unflushedBatchSurvivesFailedShutdown() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        // Pretend the consumer crashed mid-batch by making it throw forever.
        do {
            let consumer = RecordingConsumer()
            await consumer.throwOnNext(TestError("mid-batch-crash"), sticky: true)
            let queue = MessageQueue(consumer: consumer, storage: handle.storage)
            await queue.startRunloop()
            for msg in Message.sequence(prefix: "crashy", count: 3) {
                await queue.emit(msg)
            }
            _ = await eventually(timeout: 2.0) {
                await consumer.callCount >= 1
            }
            await queue.stop()
            await XCTAsyncAssertEqual(
                try await handle.storage.getQueueSize(), 3,
                "Batch must not be deleted when consumer failed"
            )
        }

        // Recover with a healthy consumer.
        let revived = try SQLiteMessageStorage(dbPath: handle.path)
        handle.storage = revived
        let consumer = RecordingConsumer()
        let queue = MessageQueue(consumer: consumer, storage: revived)
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await waitForMessages(consumer, count: 3, timeout: 5.0)
        await XCTAsyncAssertEqual(try await revived.getQueueSize(), 0)
    }
}
