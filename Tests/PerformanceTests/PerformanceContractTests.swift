//
//  PerformanceContractTests.swift
//  GalvaTests
//
//  These aren't micro-benchmarks. They're *contract* tests that lock in
//  the SDK's perf-safety guarantees so regressions surface in CI before
//  reaching customers:
//
//   1. Public API calls return synchronously in microseconds (host app
//      sees no latency from Galva on the call site).
//   2. The pending-message queue is bounded — oldest messages get
//      evicted when the cap is exceeded.
//   3. Filtered-out log calls don't evaluate their `@autoclosure`
//      message (so a `logger.debug(.queue, "expensive \(work)")` in a
//      hot loop costs ~zero when the filter is at .warning).
//
//  Bounds are deliberately loose — slow CI shouldn't flake them. They
//  exist to catch *orders-of-magnitude* regressions.
//

import Foundation
@testable import Galva
import XCTest

// MARK: - Public-API return latency

final class PublicAPIReturnLatencyTests: XCTestCase {

    /// `Galva.track(...)` is fire-and-forget. From the host app's point
    /// of view, it must return in negligible wall-clock time — the SDK
    /// hops the actual work onto `GalvaActor` via `Task { ... }`.
    func test_track_returnsSynchronouslyAndQuickly() {
        let iterations = 10_000
        let start = DispatchTime.now()
        for i in 0..<iterations {
            AppEvents.track("perf-\(i)")
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let nsPerCall = Double(elapsedNanos) / Double(iterations)
        // 50µs per call is a loose ceiling — typical is well under 5µs.
        // The threshold catches accidental sync work being added.
        XCTAssertLessThan(nsPerCall, 50_000,
            "AppEvents.track averaged \(nsPerCall) ns per call — should stay well under 50µs")
    }

    func test_identifiedUserId_isCheapSyncRead() {
        // The read goes through an NSLock to mirror the GalvaActor state.
        // 100k reads on the host thread must stay fast — this is the
        // accessor an app might call to gate "if identified" branches.
        let iterations = 100_000
        let start = DispatchTime.now()
        for _ in 0..<iterations {
            _ = AppUser.identifiedUserId
        }
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let nsPerCall = Double(elapsedNanos) / Double(iterations)
        XCTAssertLessThan(nsPerCall, 5_000,
            "AppUser.identifiedUserId averaged \(nsPerCall) ns per call — should stay well under 5µs")
    }
}

// MARK: - Bounded queue
//
// Key gotcha discovered while writing these: with `batchingWindow: nil`
// and a sticky consumer failure, every `emit` blocks waiting for the
// failed batch's exponential backoff (up to 60s per attempt). Tests
// like that take ~6 minutes each. The fix is to use a generous
// `batchingWindow` so emit doesn't synchronously trigger consumer work —
// the queue then stores + caps + returns immediately, which is the only
// thing we're testing here anyway.

final class BoundedQueueTests: XCTestCase {

    /// QueueOptions tuned for cap-only testing: the batch timer is so far
    /// in the future that the consumer is never invoked during the test,
    /// so `emit` does only store + enforce cap + return.
    private func capOnlyOptions(maxStoredCount: Int?) -> MessageQueue.QueueOptions {
        .init(
            batchingWindow: .init(timeWindow: 999, maxCount: 999),
            maxStoredCount: maxStoredCount
        )
    }

    func test_queueRespectsMaxStoredCount_evictsOldest() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(
            consumer: consumer,
            storage: storage,
            options: capOnlyOptions(maxStoredCount: 5)
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for i in 0..<10 {
            await queue.emit(.makeTrack(event: "evt-\(String(format: "%02d", i))"))
        }

        let finalSize = try await storage.getQueueSize()
        XCTAssertEqual(finalSize, 5, "Cap should be enforced after every emit")

        let remaining = try await storage.fetchMessages(limit: 100)
        let events = remaining.compactMap(\.event).sorted()
        XCTAssertEqual(events, ["evt-05", "evt-06", "evt-07", "evt-08", "evt-09"],
                       "FIFO eviction must drop oldest, keep newest")
    }

    func test_noCap_doesNotEvict() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(
            consumer: consumer,
            storage: storage,
            options: capOnlyOptions(maxStoredCount: nil)
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for i in 0..<20 {
            await queue.emit(.makeTrack(event: "u-\(i)"))
        }
        let size = try await storage.getQueueSize()
        XCTAssertEqual(size, 20, "Without a cap, no messages should be evicted")
    }

    func test_storageDropOldest_returnsActualCount() async throws {
        let storage = TestStorage.memory()
        for msg in Message.sequence(prefix: "drop", count: 3) {
            try await storage.storeMessage(msg)
        }
        // Asking to drop more than exists should drop everything and return 3.
        let dropped = try await storage.dropOldest(100)
        XCTAssertEqual(dropped, 3)
        let finalSize = try await storage.getQueueSize()
        XCTAssertEqual(finalSize, 0)
    }
}

// MARK: - Filtered logs don't evaluate autoclosures

final class FilteredLogPerformanceTests: XCTestCase {

    /// Counts how many times the message closure is invoked. Lets us
    /// prove the autoclosure short-circuit works end-to-end.
    final class CountingLogger: GalvaLogger, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var invocations: Int = 0
        func log(_ entry: Galva.LogEntry) {
            lock.lock(); invocations += 1; lock.unlock()
        }
    }

    func test_filteredOutEntries_doNotInvokeMessageClosure() {
        let counter = CountingLogger()
        let filtered = LevelFilterLogger(minLevel: .warning, wrapped: counter)

        // Build a counter on the autoclosure side too.
        let messageCounter = MessageEvaluationCounter()
        for _ in 0..<1_000 {
            filtered.debug(.queue, messageCounter.tick("debug"))
            filtered.info(.queue, messageCounter.tick("info"))
        }

        XCTAssertEqual(counter.invocations, 0, "Filtered-out entries reached the sink")
        XCTAssertEqual(messageCounter.count, 0,
            "Message autoclosure should not be evaluated for filtered entries — got \(messageCounter.count) calls")
    }

    func test_passingEntries_doInvokeMessageClosure() {
        let counter = CountingLogger()
        let filtered = LevelFilterLogger(minLevel: .debug, wrapped: counter)

        let messageCounter = MessageEvaluationCounter()
        for _ in 0..<10 {
            filtered.debug(.queue, messageCounter.tick("debug"))
            filtered.warning(.queue, messageCounter.tick("warn"))
        }

        XCTAssertEqual(counter.invocations, 20)
        XCTAssertEqual(messageCounter.count, 20)
    }

    func test_off_dropsEverything_andSkipsAutoclosure() {
        let counter = CountingLogger()
        let filtered = LevelFilterLogger(minLevel: .off, wrapped: counter)
        let messageCounter = MessageEvaluationCounter()
        filtered.debug(.queue, messageCounter.tick("d"))
        filtered.fault(.queue, messageCounter.tick("f"))
        XCTAssertEqual(counter.invocations, 0)
        XCTAssertEqual(messageCounter.count, 0)
    }

    /// Side-effecting helper that increments a counter when its message
    /// closure runs. Used to detect autoclosure evaluation from inside
    /// a test assertion.
    final class MessageEvaluationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count: Int = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

        func tick(_ label: String) -> String {
            lock.lock(); _count += 1; lock.unlock()
            return label
        }
    }
}
