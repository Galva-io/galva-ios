//
//  MessageQueueBatchingTests.swift
//  GalvaTests
//
//  Created by Claude Code on 11/9/25.
//

import Foundation
@testable import Galva
import XCTest

class MessageQueueBatchingTests: XCTestCase {
    func testBatchingByCount() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 10.0, // Long time window to ensure count-based batching
            maxCount: 3
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "batch_count_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 6, idPrefix: "batch")

        consumer.expectBatches(count: 2) // 6 messages / 3 per batch = 2 batches

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process 2 batches within timeout")
        consumer.assertConsumedMessagesCount(expected: 6)
        consumer.assertBatchCount(expected: 2)
        consumer.assertBatchSizes(expected: [3, 3])
        consumer.assertMessageOrder(expectedIds: [
            "batch_000", "batch_001", "batch_002",
            "batch_003", "batch_004", "batch_005",
        ])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testBatchingByTime() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 0.5, // 500ms time window
            maxCount: 100 // Large count to ensure time-based batching
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "batch_time_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let message1 = Message.createTestMessage(id: "time_1")
        let message2 = Message.createTestMessage(id: "time_2")

        consumer.expectBatches(count: 1)

        await messageQueue.emit(message1)
        await messageQueue.emit(message2)

        // Messages should be batched together after time window
        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 2.0), "Should process batch within timeout")
        consumer.assertConsumedMessagesCount(expected: 2)
        consumer.assertBatchCount(expected: 1)
        consumer.assertBatchSizes(expected: [2])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testBatchingMixedTriggers() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 1.0, // 1 second time window
            maxCount: 3
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "batch_mixed_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        consumer.expectBatches(count: 2)

        // First batch: triggered by count (3 messages)
        let firstBatch = Message.createTestMessages(count: 3, idPrefix: "mixed1")
        for message in firstBatch {
            await messageQueue.emit(message)
        }

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Second batch: will be triggered by time window
        let secondBatch = Message.createTestMessages(count: 2, idPrefix: "mixed2")
        for message in secondBatch {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 3.0), "Should process both batches within timeout")
        consumer.assertConsumedMessagesCount(expected: 5)
        consumer.assertBatchCount(expected: 2)
        consumer.assertBatchSizes(expected: [3, 2])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testBatchingWithLargeMessageCount() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 5.0,
            maxCount: 5
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "batch_large_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 23, idPrefix: "large")

        consumer.expectBatches(count: 5) // 23 messages: 4 batches of 5 + 1 batch of 3

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 10.0), "Should process all batches within timeout")
        consumer.assertConsumedMessagesCount(expected: 23)
        consumer.assertBatchCount(expected: 5)
        consumer.assertBatchSizes(expected: [5, 5, 5, 5, 3])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testBatchingPreservesOrder() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 1.0,
            maxCount: 4
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "batch_order_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 10, idPrefix: "order")

        consumer.expectBatches(count: 3) // 10 messages: 2 batches of 4 + 1 batch of 2

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process all batches within timeout")

        let expectedOrder = (0 ..< 10).map { "order_\(String(format: "%03d", $0))" }
        consumer.assertMessageOrder(expectedIds: expectedOrder)

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testBatchingWithConsumerError() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 1.0,
            maxCount: 3
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "batch_error_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        // Set up error on first batch
        consumer.errorToThrow = MessageQueueError("Batch processing error")

        let messages = Message.createTestMessages(count: 6, idPrefix: "error")

        for message in messages {
            await messageQueue.emit(message)
        }

        // Wait for processing attempts
        try await Task.sleep(nanoseconds: 500_000_000) // 500ms

        // All messages should remain in queue due to error
        let queueSize = try await messageQueue.size
        XCTAssertEqual(queueSize, 6, "All messages should remain in queue after error")

        // Clear error and allow processing
        consumer.errorToThrow = nil
        consumer.reset() // Reset counts before final processing
        consumer.expectBatches(count: 2)

        // Processing should resume and complete
        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 3.0), "Should process all batches after error cleared")
        consumer.assertConsumedMessagesCount(expected: 6)

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testNoBatchingMode() async throws {
        let consumer = MockMessageConsumer()
        // No batching options - each message processed individually
        let queueName = "no_batch_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: nil, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 5, idPrefix: "individual")

        consumer.expectBatches(count: 5) // Each message triggers its own batch

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process each message individually")
        consumer.assertConsumedMessagesCount(expected: 5)
        consumer.assertBatchCount(expected: 5)
        consumer.assertBatchSizes(expected: [1, 1, 1, 1, 1])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testEmptyBatchingWindow() async throws {
        let consumer = MockMessageConsumer()
        let options = MessageQueue.QueueOptions(batchingWindow: nil)
        let queueName = "empty_batch_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 3, idPrefix: "empty")

        consumer.expectBatches(count: 3) // Should behave like no batching

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "Should process each message individually")
        consumer.assertBatchCount(expected: 3)
        consumer.assertBatchSizes(expected: [1, 1, 1])

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }
}
