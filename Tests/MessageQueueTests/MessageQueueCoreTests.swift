//
//  MessageQueueCoreTests.swift
//  GalvaTests
//
//  Created by Claude Code on 11/9/25.
//

import Foundation
@testable import Galva
import XCTest

class MessageQueueCoreTests: XCTestCase {
    func testBasicMessageEmissionAndProcessing() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "basic_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let testMessage = Message.createTestMessage(id: "test-1")

        consumer.expectBatches(count: 1)
        await messageQueue.emit(testMessage)

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process message within timeout")
        consumer.assertConsumedMessagesCount(expected: 1)
        consumer.assertBatchCount(expected: 1)
        consumer.assertMessageOrder(expectedIds: ["test-1"])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testMultipleMessageEmissionAndProcessing() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "multiple_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 5, idPrefix: "multi")

        consumer.expectBatches(count: 5) // No batching, each message processed individually

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process all messages within timeout")
        consumer.assertConsumedMessagesCount(expected: 5)
        consumer.assertMessageOrder(expectedIds: ["multi_000", "multi_001", "multi_002", "multi_003", "multi_004"])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testMessageOrdering() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "ordering_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let message1 = Message.createTestMessage(id: "first")
        let message2 = Message.createTestMessage(id: "second")
        let message3 = Message.createTestMessage(id: "third")

        consumer.expectBatches(count: 3)

        await messageQueue.emit(message1)
        await messageQueue.emit(message2)
        await messageQueue.emit(message3)

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process all messages within timeout")
        consumer.assertMessageOrder(expectedIds: ["first", "second", "third"])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testQueueSize() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "size_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let initialSize = try await messageQueue.size
        XCTAssertEqual(initialSize, 0, "Queue should start empty")

        // Stop the queue to prevent processing
        await messageQueue.stop()

        // Emit messages while queue is stopped
        let messages = Message.createTestMessages(count: 3)
        for message in messages {
            await messageQueue.emit(message)
        }

        let queueSize = try await messageQueue.size
        XCTAssertEqual(queueSize, 3, "Queue should have 3 messages when stopped")

        // Clear the queue
        try await messageQueue.clearQueue()

        let finalSize = try await messageQueue.size
        XCTAssertEqual(finalSize, 0, "Queue should be empty after clear")
    }

    func testClearQueue() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "clear_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        // Stop the queue to prevent processing
        await messageQueue.stop()

        let messages = Message.createTestMessages(count: 5)
        for message in messages {
            await messageQueue.emit(message)
        }

        let sizeBeforeClear = try await messageQueue.size
        XCTAssertEqual(sizeBeforeClear, 5, "Queue should have 5 messages before clear")

        try await messageQueue.clearQueue()

        let sizeAfterClear = try await messageQueue.size
        XCTAssertEqual(sizeAfterClear, 0, "Queue should be empty after clear")
    }

    func testConsumerErrorHandling() async throws {
        let testError = MessageQueueError("Consumer error")
        let consumer = MockMessageConsumer()
        consumer.errorToThrow = testError

        let queueName = "error_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let testMessage = Message.createTestMessage(id: "error-test")

        await messageQueue.emit(testMessage)

        // Give time for processing attempt
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // Message should remain in queue due to error
        let queueSize = try await messageQueue.size
        XCTAssertGreaterThan(queueSize, 0, "Message should remain in queue after consumer error")

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testStopQueue() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "stop_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let testMessage = Message.createTestMessage(id: "stop-test")

        await messageQueue.stop()
        await messageQueue.emit(testMessage)

        // Give time for any potential processing
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        consumer.assertConsumedMessagesCount(expected: 0)

        let queueSize = try await messageQueue.size
        XCTAssertGreaterThan(queueSize, 0, "Message should be stored but not processed after stop")

        try await messageQueue.clearQueue()
    }
}
