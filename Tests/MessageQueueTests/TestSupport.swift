//
//  TestSupport.swift
//  GalvaTests
//
//  Shared fixtures, the recording consumer, and tiny helpers used across
//  every MessageQueue test suite.
//
//  Design notes
//  ━━━━━━━━━━━━
//  • RecordingConsumer is a real Swift actor — every mutation is serialised
//    by the actor runtime, no semaphores, no @unchecked Sendable.
//  • Tests synchronise on `XCTestExpectation` (idiomatic XCTest) rather
//    than the consumer signalling a semaphore.
//  • Test messages are random UUIDv7 (just like production). Tests must
//    NEVER assert on `messageId`; they tag each message with an `event`
//    name and assert on that. This keeps the factory honest and the
//    assertions semantic.
//

import Foundation
@testable import Galva
import XCTest

// MARK: - RecordingConsumer

/// Records every batch the queue hands it, with optional injected error and
/// per-call hook. Thread-safe by virtue of being an actor.
actor RecordingConsumer: MessageConsumer {
    private(set) var batches: [[Message]] = []
    private(set) var callCount: Int = 0

    /// Error to throw on the next `consume(...)`. Cleared after one use unless
    /// `errorIsSticky` is true.
    private var pendingError: Error?
    private var errorIsSticky: Bool = false

    /// Hook fired *before* a batch is acknowledged. Lets tests inject a
    /// delay, observe a batch, or trigger a side-effect.
    private var beforeConsume: (@Sendable ([Message]) async throws -> Void)?

    init() {}

    func consume(messages: [Message]) async throws {
        callCount += 1
        batches.append(messages)
        if let beforeConsume {
            try await beforeConsume(messages)
        }
        if let pendingError {
            if !errorIsSticky { self.pendingError = nil }
            throw pendingError
        }
    }

    // Configuration --------------------------------------------------------

    func throwOnNext(_ error: Error, sticky: Bool = false) {
        pendingError = error
        errorIsSticky = sticky
    }

    func clearError() {
        pendingError = nil
        errorIsSticky = false
    }

    func setBeforeConsume(_ hook: (@Sendable ([Message]) async throws -> Void)?) {
        beforeConsume = hook
    }

    // Queries --------------------------------------------------------------

    /// All consumed messages flattened in batch order.
    var allMessages: [Message] { batches.flatMap { $0 } }

    /// `event` field of every consumed track message, in order.
    var consumedEvents: [String] { allMessages.compactMap(\.event) }

    /// Number of batches with size matching `predicate`.
    func batchSizes() -> [Int] { batches.map(\.count) }

    func reset() {
        batches.removeAll()
        callCount = 0
        pendingError = nil
        errorIsSticky = false
        beforeConsume = nil
    }
}

// MARK: - Expectation helpers

/// Poll an async condition until it returns true or `timeout` elapses. Use
/// this instead of fixed-duration `Task.sleep` — passes immediately when the
/// condition is satisfied and only times out if something is wrong.
@discardableResult
func eventually(
    timeout: TimeInterval = 2.0,
    poll: TimeInterval = 0.02,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () async throws -> Bool
) async -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        if (try? await condition()) == true {
            return true
        }
        try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
    }
    XCTFail("eventually(...) timed out after \(timeout)s", file: file, line: line)
    return false
}

/// Wait for the consumer to have consumed at least `count` total messages.
func waitForMessages(
    _ consumer: RecordingConsumer,
    count: Int,
    timeout: TimeInterval = 2.0,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    _ = await eventually(timeout: timeout, file: file, line: line) {
        await consumer.allMessages.count >= count
    }
}

// MARK: - Message fixtures

extension Message {
    /// Builds a `.track` Message whose event name is `event`. Use the event
    /// name as the assertion key — `messageId` is always a random UUIDv7.
    static func makeTrack(
        event: String,
        properties: [String: AnyJSONValue]? = nil,
        userId: String? = nil,
        anonymousId: String? = "anon_test"
    ) -> Message {
        Message(
            anonymousId: anonymousId,
            endUserId: userId,
            timestamp: Date(),
            context: nil,
            body: .track(event: event, properties: properties, sourceType: nil, sourceId: nil)
        )
    }

    /// Builds an `.identify` Message with the given traits.
    static func makeIdentify(
        userId: String? = "user_test",
        anonymousId: String? = "anon_test",
        traits: [String: AnyJSONValue]? = nil
    ) -> Message {
        Message(
            anonymousId: anonymousId,
            endUserId: userId,
            timestamp: Date(),
            context: nil,
            body: .identify(traits: traits)
        )
    }

    /// Sequence of `.track` messages tagged `<prefix>-000`, `<prefix>-001`, …
    /// Use `consumedEvents` from the consumer to assert order.
    static func sequence(prefix: String, count: Int) -> [Message] {
        (0 ..< count).map { idx in
            makeTrack(event: "\(prefix)-\(String(format: "%03d", idx))")
        }
    }
}

// MARK: - Storage factories

enum TestStorage {
    /// Spin up a SQLite store backed by a unique file under the OS temp dir.
    /// Caller is responsible for releasing the storage and deleting the file
    /// — `TempSQLiteHandle` does both on `cleanup()`.
    static func sqlite(file: StaticString = #filePath) throws -> TempSQLiteHandle {
        let path = NSTemporaryDirectory()
            .appending("galva-test-\(UUID().uuidString).db")
        let storage = try SQLiteMessageStorage(dbPath: path)
        return TempSQLiteHandle(storage: storage, path: path)
    }

    static func memory() -> InMemoryMessageStorage {
        InMemoryMessageStorage()
    }
}

final class TempSQLiteHandle: @unchecked Sendable {
    var storage: SQLiteMessageStorage
    let path: String
    private var cleaned = false

    init(storage: SQLiteMessageStorage, path: String) {
        self.storage = storage
        self.path = path
    }

    func cleanup() {
        guard !cleaned else { return }
        cleaned = true
        try? FileManager.default.removeItem(atPath: path)
    }

    deinit { cleanup() }
}

// MARK: - Async-friendly assertion helpers
//
// XCTAssertEqual's autoclosure parameter is sync — it can't accept
// `await ...`. These tiny wrappers evaluate the async expression first
// and then forward to XCTest, keeping call sites readable.

func XCTAsyncAssertEqual<T: Equatable>(
    _ actual: @autoclosure () async throws -> T,
    _ expected: T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await actual()
        XCTAssertEqual(value, expected, message(), file: file, line: line)
    } catch {
        XCTFail("Threw: \(error). \(message())", file: file, line: line)
    }
}

func XCTAsyncAssertTrue(
    _ actual: @autoclosure () async throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await actual()
        XCTAssertTrue(value, message(), file: file, line: line)
    } catch {
        XCTFail("Threw: \(error). \(message())", file: file, line: line)
    }
}

// MARK: - Misc

struct TestError: Error, Equatable {
    let label: String
    init(_ label: String = "test-error") { self.label = label }
}
