//
//  MessageQueueResilienceTests.swift
//  GalvaTests
//
//  Covers what happens when things go wrong:
//    • Consumer throws → batch retained, retried on next tick.
//    • Sticky failures → exponential backoff (we assert the queue tries
//      again instead of livelocking).
//    • Recovery → once the consumer stops throwing, drained.
//    • The on-disk row count never silently shrinks when a batch fails.
//

import Foundation
@testable import Galva
import XCTest

final class MessageQueueResilienceTests: XCTestCase {

    // MARK: - Single transient failure → recovery

    func test_consumerThrowsOnce_thenRecovers_deliversAllMessages() async throws {
        // A batching window is required for the retry-on-timer path. Without
        // one, the only drain trigger is a new emit; a failed batch would
        // sit forever. Production always configures a window (see SDKCore).
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(
            consumer: consumer,
            storage: storage,
            options: .init(batchingWindow: .init(timeWindow: 0.2, maxCount: 100))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await consumer.throwOnNext(TestError("first-attempt"), sticky: false)

        await queue.emit(.makeTrack(event: "transient"))

        await waitForMessages(consumer, count: 2, timeout: 5.0)
        // The same message is delivered twice (one failed attempt + retry).
        let events = await consumer.consumedEvents
        XCTAssertEqual(events.filter { $0 == "transient" }.count, 2)

        // After the retry succeeds the batch is removed from storage.
        _ = await eventually(timeout: 2.0) {
            try await storage.getQueueSize() == 0
        }
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0,
                                  "Successful retry should clear the batch")
    }

    // MARK: - Persistent failure → batch retained on disk

    func test_consumerThrowsForever_batchRemainsInStorage() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(consumer: consumer, storage: storage)
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await consumer.throwOnNext(TestError("permanent"), sticky: true)

        for msg in Message.sequence(prefix: "stuck", count: 3) {
            await queue.emit(msg)
        }

        // Give the queue room to retry a few times against the sticky error.
        _ = await eventually(timeout: 2.0) {
            await consumer.callCount >= 2
        }

        let sizeAfter = try await storage.getQueueSize()
        XCTAssertEqual(sizeAfter, 3, "All 3 messages must remain in storage while failing")
    }

    // MARK: - Recovery after sticky failure is cleared

    func test_clearError_drainsBacklog() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(
            consumer: consumer,
            storage: storage,
            options: .init(batchingWindow: .init(timeWindow: 0.2, maxCount: 100))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await consumer.throwOnNext(TestError("hold"), sticky: true)

        for msg in Message.sequence(prefix: "drain", count: 4) {
            await queue.emit(msg)
        }
        // Let one failed attempt happen.
        _ = await eventually(timeout: 2.0) {
            await consumer.callCount >= 1
        }
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 4)

        // Clear the error — next timer tick should drain.
        await consumer.clearError()
        _ = await eventually(timeout: 5.0) {
            try await storage.getQueueSize() == 0
        }

        // Backlog was processed at least once after recovery.
        let allEvents = await consumer.consumedEvents
        let expected = (0 ..< 4).map { "drain-\(String(format: "%03d", $0))" }
        XCTAssertEqual(
            Set(allEvents).intersection(expected),
            Set(expected),
            "Backlog was not fully delivered after recovery"
        )
    }

    // MARK: - Backoff escalates between consecutive failures

    func test_backoff_escalatesBetweenAttempts() async throws {
        // We don't pin exact durations (those are jittered) — instead assert
        // that consecutive failures don't tight-loop. With consecutive sticky
        // failures and a 0.05s time window, naive non-backoff would burst
        // dozens of consume() calls in 1s. With backoff, attempts should
        // remain bounded.
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(
            consumer: consumer,
            storage: storage,
            options: .init(batchingWindow: .init(timeWindow: 0.05, maxCount: 10))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        await consumer.throwOnNext(TestError("hammer"), sticky: true)
        await queue.emit(.makeTrack(event: "loop"))

        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        let calls = await consumer.callCount
        XCTAssertLessThan(calls, 50, "Backoff should bound retries (got \(calls) in 1.5s)")
    }

    // MARK: - Storage failure isolation: clear after fail keeps queue alive

    func test_clearQueueAfterFailure_keepsQueueUsable() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(consumer: consumer, storage: storage)
        await queue.startRunloop()

        await consumer.throwOnNext(TestError("fail-then-clear"), sticky: true)
        await queue.emit(.makeTrack(event: "to-be-cleared"))

        _ = await eventually(timeout: 2.0) {
            await consumer.callCount >= 1
        }
        try await queue.clearQueue()

        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0)

        // Queue is now stopped (clearQueue cancels the processing task).
        // Restart and emit a new message; it should flow through.
        await queue.startRunloop()
        await consumer.clearError()
        await queue.emit(.makeTrack(event: "post-clear"))

        await waitForMessages(consumer, count: 2)
        let events = await consumer.consumedEvents
        XCTAssertTrue(events.contains("post-clear"))

        await queue.stop()
    }
}
