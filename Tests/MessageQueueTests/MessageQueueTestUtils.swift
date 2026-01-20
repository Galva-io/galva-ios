//
//  MessageQueueTestUtils.swift
//  GalvaTests
//
//  Created by Claude Code on 11/9/25.
//

import Dispatch
import Foundation
@testable import Galva
import XCTest

class MockMessageConsumer: MessageConsumer, @unchecked Sendable {
    private var consumeCallback: (([Message]) async throws -> Void)?
    private var consumeCallbacks: [([Message]) async throws -> Void] = []

    var consumedMessages: [[Message]] = []
    var consumeCount = 0
    var totalMessagesConsumed = 0
    var errorToThrow: Error?

    private let semaphore = DispatchSemaphore(value: 0)
    private var expectedBatches = 0
    private var receivedBatches = 0

    // Unique identifier to avoid cross-test contamination
    private let id = UUID().uuidString

    init(onConsume: (([Message]) async throws -> Void)? = nil) {
        consumeCallback = onConsume
    }

    func consume(messages: [Message]) async throws {
        consumedMessages.append(messages)
        consumeCount += 1
        totalMessagesConsumed += messages.count
        receivedBatches += 1

        if let error = errorToThrow {
            throw error
        }

        if let callback = consumeCallback {
            try await callback(messages)
        } else if !consumeCallbacks.isEmpty, consumeCallbacks.count >= consumeCount {
            try await consumeCallbacks[consumeCount - 1](messages)
        }

        if receivedBatches >= expectedBatches {
            semaphore.signal()
        }
    }

    func expectBatches(count: Int, timeout _: TimeInterval = 10.0) {
        expectedBatches = count
        receivedBatches = 0
    }

    func waitForExpectedBatches(timeout: TimeInterval = 10.0) -> Bool {
        let timeoutTime = DispatchTime.now() + timeout
        return semaphore.wait(timeout: timeoutTime) == .success
    }

    func addCallback(_ callback: @escaping ([Message]) async throws -> Void) {
        consumeCallbacks.append(callback)
    }

    func assertConsumedMessagesCount(expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(totalMessagesConsumed, expected, "Expected \(expected) total messages, got \(totalMessagesConsumed)", file: file, line: line)
    }

    func assertBatchCount(expected: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(consumeCount, expected, "Expected \(expected) batches, got \(consumeCount)", file: file, line: line)
    }

    func assertMessageOrder(expectedIds: [String], file: StaticString = #filePath, line: UInt = #line) {
        let allMessages = consumedMessages.flatMap { $0 }
        let actualIds = allMessages.map { $0.id }
        XCTAssertEqual(actualIds, expectedIds, "Message order mismatch", file: file, line: line)
    }

    func assertBatchSizes(expected: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let actualBatchSizes = consumedMessages.map { $0.count }
        XCTAssertEqual(actualBatchSizes, expected, "Batch size mismatch", file: file, line: line)
    }

    func reset() {
        consumedMessages.removeAll()
        consumeCount = 0
        totalMessagesConsumed = 0
        errorToThrow = nil
        expectedBatches = 0
        receivedBatches = 0
        consumeCallbacks.removeAll()
        // Don't reset the main callback as it might be set in init
    }
}

extension Message {
    static func createTestMessage(
        id: String? = nil,
        type: MessageType = .track,
        userId: String? = nil,
        anonymousId: String? = nil,
        event: String? = "test_event",
        properties: [String: Any]? = nil
    ) -> Message {
        let messageId = id ?? UUID().uuidString
        let now = Date()

        let context = Message.Context(
            app: Message.App(
                name: "TestApp",
                version: "1.0.0",
                build: "1",
                namespace: "com.test.app"
            ),
            device: Message.Device(
                id: "test-device-id",
                model: "iPhone",
                name: "Test iPhone",
                manufacturer: "Apple",
                type: "mobile"
            ),
            os: Message.OS(
                name: "iOS",
                version: "17.0"
            ),
            locale: "en",
            timezone: "America/New_York",
            library: Message.Library(
                name: "Galva",
                version: "1.0.0"
            ),
            extra: nil
        )

        return Message(
            id: messageId,
            type: type,
            userId: userId,
            anonymousId: anonymousId,
            timestamp: now,
            apiVersion: "1.0",
            event: event,
            properties: properties,
            traits: nil,
            context: context
        )
    }

    static func createTestMessages(count: Int, idPrefix: String = "msg") -> [Message] {
        return (0 ..< count).map { index in
            createTestMessage(
                id: "\(idPrefix)_\(String(format: "%03d", index))",
                event: "test_event_\(index)"
            )
        }
    }
}

actor MessageQueueError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension MessageQueueError: Equatable {
    static func == (lhs: MessageQueueError, rhs: MessageQueueError) -> Bool {
        return lhs.message == rhs.message
    }
}

class AsyncTestHelper {
    static func wait(for condition: @escaping () async throws -> Bool, timeout: TimeInterval = 10.0, pollingInterval: TimeInterval = 0.1) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if try await condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
        }

        throw MessageQueueError("Timeout waiting for condition")
    }
}
