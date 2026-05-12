//
//  MessageQueueContractTests.swift
//  GalvaTests
//
//  Covers the queue's user-visible contract:
//    • FIFO delivery
//    • Batching by count and by time
//    • Per-batch size cap (server limit)
//    • No-batching mode (each emit triggers consume immediately)
//
//  All tests inject an in-memory storage so they're fast and never touch
//  the filesystem. Durability and SQLite-specific behaviour live in
//  separate suites.
//

import Foundation
@testable import Galva
import XCTest

final class MessageQueueContractTests: XCTestCase {

    // MARK: - FIFO

    func test_emit_thenStop_preservesEmitOrder() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(consumer: consumer, storage: TestStorage.memory())
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for msg in Message.sequence(prefix: "fifo", count: 8) {
            await queue.emit(msg)
        }

        await waitForMessages(consumer, count: 8)
        let events = await consumer.consumedEvents
        XCTAssertEqual(events, (0 ..< 8).map { "fifo-\(String(format: "%03d", $0))" })
    }

    // MARK: - Batching by count

    func test_batchingByCount_drainsAtThreshold() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(
            consumer: consumer,
            storage: TestStorage.memory(),
            options: .init(batchingWindow: .init(timeWindow: 60, maxCount: 3))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for msg in Message.sequence(prefix: "by-count", count: 6) {
            await queue.emit(msg)
        }

        await waitForMessages(consumer, count: 6)
        let sizes = await consumer.batchSizes()
        XCTAssertEqual(sizes, [3, 3])
    }

    func test_batchingByCount_leftoversWaitForTime() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(
            consumer: consumer,
            storage: TestStorage.memory(),
            options: .init(batchingWindow: .init(timeWindow: 0.3, maxCount: 5))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        // 7 messages → first batch of 5 by count, remaining 2 wait for the timer.
        for msg in Message.sequence(prefix: "left", count: 7) {
            await queue.emit(msg)
        }
        await waitForMessages(consumer, count: 7, timeout: 3.0)
        let sizes = await consumer.batchSizes()
        XCTAssertEqual(sizes, [5, 2])
    }

    // MARK: - Batching by time

    func test_batchingByTime_drainsUnderThreshold() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(
            consumer: consumer,
            storage: TestStorage.memory(),
            options: .init(batchingWindow: .init(timeWindow: 0.2, maxCount: 100))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await queue.emit(.makeTrack(event: "time-a"))
        await queue.emit(.makeTrack(event: "time-b"))

        await waitForMessages(consumer, count: 2, timeout: 2.0)
        let events = await consumer.consumedEvents
        XCTAssertEqual(events, ["time-a", "time-b"])
        let count = await consumer.callCount
        XCTAssertEqual(count, 1, "Two emits should be a single time-windowed batch")
    }

    // MARK: - Per-batch cap (server limit = 100)

    func test_batchCap_respectsMaxBatchSize() async throws {
        let consumer = RecordingConsumer()
        // Configure a maxCount LARGER than the server cap to prove the queue
        // still clamps each batch to SDKConstants.maxBatchSize. timeWindow
        // is short so the test isn't gated on the count trigger.
        let queue = MessageQueue(
            consumer: consumer,
            storage: TestStorage.memory(),
            options: .init(batchingWindow: .init(timeWindow: 0.2, maxCount: 500))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        // 250 emits → at most 100/batch.
        for msg in Message.sequence(prefix: "cap", count: 250) {
            await queue.emit(msg)
        }
        // We stop once everything's been drained.
        await waitForMessages(consumer, count: 250, timeout: 5.0)
        let sizes = await consumer.batchSizes()
        for size in sizes {
            XCTAssertLessThanOrEqual(size, SDKConstants.maxBatchSize,
                                     "Batch larger than server cap: \(size)")
        }
        XCTAssertEqual(sizes.reduce(0, +), 250)
    }

    // MARK: - No-batching mode

    func test_noBatching_eachEmitTriggersConsume() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(consumer: consumer, storage: TestStorage.memory(), options: nil)
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for msg in Message.sequence(prefix: "solo", count: 4) {
            await queue.emit(msg)
        }

        await waitForMessages(consumer, count: 4)
        let sizes = await consumer.batchSizes()
        XCTAssertEqual(sizes, [1, 1, 1, 1])
    }

    // MARK: - Nil batchingWindow == no batching

    func test_nilBatchingWindow_equivalentToNoOptions() async throws {
        let consumer = RecordingConsumer()
        let queue = MessageQueue(
            consumer: consumer,
            storage: TestStorage.memory(),
            options: .init(batchingWindow: nil)
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for msg in Message.sequence(prefix: "nil-win", count: 3) {
            await queue.emit(msg)
        }

        await waitForMessages(consumer, count: 3)
        let sizes = await consumer.batchSizes()
        XCTAssertEqual(sizes, [1, 1, 1])
    }
}
