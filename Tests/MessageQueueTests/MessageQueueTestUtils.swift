//
//  MessageQueueTestUtils.swift
//  GalvaTests
//
//  Updated for the OpenAPI-aligned Message model.
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
    }
}

extension Message {
    /// Builds a `track` Message for tests. If `id` is provided and parses as a
    /// UUID, it's used as `messageId`; otherwise a UUIDv7 is generated and the
    /// seed is ignored. Use `createTestMessageWithMappedId` for deterministic
    /// non-UUID string seeds.
    static func createTestMessage(
        id: String? = nil,
        type: Message.MessageType = .track,
        userId: String? = nil,
        anonymousId: String? = nil,
        event: String? = "test_event",
        properties: [String: Any]? = nil
    ) -> Message {
        let messageId: UUID
        if let id, let parsed = UUID(uuidString: id) {
            messageId = parsed
        } else {
            messageId = UUIDv7.next()
        }

        // Coerce [String: Any] → [String: AnyJSONValue] for the wire model.
        let coercedProperties: [String: AnyJSONValue]? = properties.map { dict in
            dict.compactMapValues { value -> AnyJSONValue? in
                switch value {
                case let v as Bool:    return .bool(v)
                case let v as Int:     return .int(Int64(v))
                case let v as Int64:   return .int(v)
                case let v as Double:  return .double(v)
                case let v as String:  return .string(v)
                default:               return .string(String(describing: value))
                }
            }
        }

        let context = MessageContext(
            app: .init(name: "TestApp", version: "1.0.0", build: "1", namespace: "com.test.app"),
            device: .init(id: "test-device-id", advertisingId: nil, adTrackingEnabled: nil,
                          manufacturer: "Apple", model: "iPhone", name: "Test iPhone",
                          type: "phone", token: nil, version: nil),
            ip: nil,
            library: .init(name: "swift", version: "1.0.0"),
            locale: "en_US",
            network: nil,
            os: .init(name: "iOS", version: "17.0"),
            page: nil,
            referrer: nil,
            screen: nil,
            timezone: "America/New_York",
            userAgent: nil,
            userAgentData: nil
        )

        let body: Message.Body
        switch type {
        case .identify:
            body = .identify(traits: coercedProperties)
        case .alias:
            body = .alias(previousId: "anon_prev", targetId: userId ?? "target")
        case .track, .createCommunicationEndpoint, .deleteCommunicationEndpoint, .setCommunicationPreference:
            body = .track(event: event ?? "test_event", properties: coercedProperties, sourceType: nil, sourceId: nil)
        }

        return Message(
            messageId: messageId,
            anonymousId: anonymousId,
            endUserId: userId,
            timestamp: Date(),
            context: context,
            body: body
        )
    }

    /// Helper for ordering tests — generates `count` messages and returns them
    /// alongside their generated IDs. Callers should assert against `.map(\.id)`.
    static func createTestMessages(count: Int, idPrefix _: String = "msg") -> [Message] {
        (0 ..< count).map { idx in
            createTestMessage(event: "test_event_\(idx)")
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
