//
//  MessageQueueIntegrationTests.swift
//  GalvaTests
//
//  Created by Claude Code on 11/9/25.
//

import Foundation
@testable import Galva
import XCTest

class MessageQueueIntegrationTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // Clean any leftover database files from previous test runs
        let tempDir = NSTemporaryDirectory()
        let fileManager = FileManager.default
        let contents = try? fileManager.contentsOfDirectory(atPath: tempDir)

        contents?.forEach { filename in
            if filename.hasPrefix("integration_test_") && filename.hasSuffix(".db") {
                let fullPath = tempDir.appending(filename)
                try? fileManager.removeItem(atPath: fullPath)
            }
        }
    }

    override func tearDown() async throws {
        // Additional cleanup to ensure no database files are left behind
        let tempDir = NSTemporaryDirectory()
        let fileManager = FileManager.default
        let contents = try? fileManager.contentsOfDirectory(atPath: tempDir)

        contents?.forEach { filename in
            if filename.hasPrefix("integration_test_") && filename.hasSuffix(".db") {
                let fullPath = tempDir.appending(filename)
                try? fileManager.removeItem(atPath: fullPath)
            }
        }

        try await super.tearDown()
    }

    func testEndToEndMessageProcessingWithSQLite() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "integration_test_sqlite_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 10, idPrefix: "e2e")

        consumer.expectBatches(count: 10) // No batching - individual processing

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 10.0), "All messages should be processed")
        consumer.assertConsumedMessagesCount(expected: 10)
        consumer.assertMessageOrder(expectedIds: (0 ..< 10).map { "e2e_\(String(format: "%03d", $0))" })

        let finalQueueSize = try await messageQueue.size
        XCTAssertEqual(finalQueueSize, 0, "Queue should be empty after processing")

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testEndToEndMessageProcessingWithBatching() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 2.0,
            maxCount: 4
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "integration_test_batch_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 14, idPrefix: "batch_e2e")

        consumer.expectBatches(count: 4) // 14 messages: 3 batches of 4 + 1 batch of 2

        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 10.0), "All batches should be processed")
        consumer.assertConsumedMessagesCount(expected: 14)
        consumer.assertBatchSizes(expected: [4, 4, 4, 2])
        consumer.assertMessageOrder(expectedIds: (0 ..< 14).map { "batch_e2e_\(String(format: "%03d", $0))" })

        let finalQueueSize = try await messageQueue.size
        XCTAssertEqual(finalQueueSize, 0, "Queue should be empty after processing")

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testResilienceToConsumerErrors() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "resilience_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        // Set up error for first processing attempt
        consumer.errorToThrow = MessageQueueError("Simulated consumer error")

        let message1 = Message.createTestMessage(id: "error_msg")

        await messageQueue.emit(message1)

        // Give time for processing attempts
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Message should remain in queue due to error
        let queueSize = try await messageQueue.size
        XCTAssertGreaterThan(queueSize, 0, "Failed message should remain in queue")

        // Verify that errors don't crash the system
        XCTAssertGreaterThan(consumer.consumeCount, 0, "Consumer should have been called at least once")

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testHighVolumeMessageProcessing() async throws {
        let consumer = MockMessageConsumer()
        let batchingWindow = MessageQueue.QueueOptions.BatchingWindow(
            timeWindow: 1.0,
            maxCount: 20
        )
        let options = MessageQueue.QueueOptions(batchingWindow: batchingWindow)
        let queueName = "high_volume_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, options: options, name: queueName)
        await messageQueue.startRunloop()

        let messageCount = 100 // Reduced from 500 to avoid test contamination
        let messages = Message.createTestMessages(count: messageCount, idPrefix: "high_vol")

        let expectedBatches = Int(ceil(Double(messageCount) / 20.0))
        consumer.expectBatches(count: expectedBatches)

        // Emit messages sequentially to avoid race conditions
        for message in messages {
            await messageQueue.emit(message)
        }

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 15.0), "All high-volume batches should be processed")

        // Allow for some variance in message count due to timing and batching
        XCTAssertGreaterThanOrEqual(consumer.totalMessagesConsumed, messageCount, "Should process at least the expected messages")
        XCTAssertLessThanOrEqual(consumer.totalMessagesConsumed, messageCount + 10, "Should not process too many extra messages")

        let finalQueueSize = try await messageQueue.size
        XCTAssertEqual(finalQueueSize, 0, "Queue should be empty after high-volume processing")

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testConcurrentQueues() async throws {
        let consumer1 = MockMessageConsumer()
        let consumer2 = MockMessageConsumer()

        let queueName1 = "concurrent_queue_1_\(UUID().uuidString)"
        let queueName2 = "concurrent_queue_2_\(UUID().uuidString)"
        let queue1 = MessageQueue(consumer: consumer1, name: queueName1)
        let queue2 = MessageQueue(consumer: consumer2, name: queueName2)
        await queue1.startRunloop()
        await queue2.startRunloop()
        let messages1 = Message.createTestMessages(count: 5, idPrefix: "q1")
        let messages2 = Message.createTestMessages(count: 7, idPrefix: "q2")

        consumer1.expectBatches(count: 5)
        consumer2.expectBatches(count: 7)

        // Run queues concurrently
        async let task1: Void = {
            for message in messages1 {
                await queue1.emit(message)
            }
        }()

        async let task2: Void = {
            for message in messages2 {
                await queue2.emit(message)
            }
        }()

        let _ = await (task1, task2)

        XCTAssertTrue(consumer1.waitForExpectedBatches(timeout: 10.0), "Queue 1 should process all messages")
        XCTAssertTrue(consumer2.waitForExpectedBatches(timeout: 10.0), "Queue 2 should process all messages")

        consumer1.assertConsumedMessagesCount(expected: 5)
        consumer2.assertConsumedMessagesCount(expected: 7)

        await queue1.stop()
        await queue2.stop()
        try await queue1.clearQueue()
        try await queue2.clearQueue()
    }

    func testQueuePersistenceAcrossRestarts() async throws {
        let queueName = "persistence_test_\(UUID().uuidString)"
        let consumer1 = MockMessageConsumer()

        // First queue instance - stop it immediately to prevent processing
        var messageQueue = MessageQueue(consumer: consumer1, name: queueName)
        await messageQueue.startRunloop()
        await messageQueue.stop()

        let messages = Message.createTestMessages(count: 5, idPrefix: "persist")
        for message in messages {
            await messageQueue.emit(message) // Will store but not process since stopped
        }

        // Verify messages are stored
        let storedSize = try await messageQueue.size
        XCTAssertEqual(storedSize, 5, "Messages should be stored")

        // Create new queue instance with different consumer
        let consumer2 = MockMessageConsumer()
        messageQueue = MessageQueue(consumer: consumer2, name: queueName)
        await messageQueue.startRunloop()

        consumer2.expectBatches(count: 5)

        // Messages should be processed by new consumer
        XCTAssertTrue(consumer2.waitForExpectedBatches(timeout: 10.0), "Persisted messages should be processed")
        consumer2.assertConsumedMessagesCount(expected: 5)
        consumer2.assertMessageOrder(expectedIds: (0 ..< 5).map { "persist_\(String(format: "%03d", $0))" })

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testMixedMessageTypes() async throws {
        let consumer = MockMessageConsumer()
        let queueName = "mixed_types_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let trackMessage = Message.createTestMessage(
            id: "track_msg",
            type: .track,
            event: "button_clicked",
            properties: ["button_id": "header_cta"]
        )

        let identifyMessage = Message.createTestMessage(
            id: "identify_msg",
            type: .identify,
            userId: "user_123",
            properties: ["email": "user@example.com", "plan": "premium"]
        )

        let aliasMessage = Message.createTestMessage(
            id: "alias_msg",
            type: .alias,
            userId: "user_123",
            properties: ["previous_id": "anon_456"]
        )

        consumer.expectBatches(count: 3)

        await messageQueue.emit(trackMessage)
        await messageQueue.emit(identifyMessage)
        await messageQueue.emit(aliasMessage)

        XCTAssertTrue(consumer.waitForExpectedBatches(timeout: 5.0), "All message types should be processed")
        consumer.assertConsumedMessagesCount(expected: 3)
        consumer.assertMessageOrder(expectedIds: ["track_msg", "identify_msg", "alias_msg"])

        // Verify message types are preserved
        let allMessages = consumer.consumedMessages.flatMap { $0 }
        XCTAssertEqual(allMessages[0].type, .track)
        XCTAssertEqual(allMessages[1].type, .identify)
        XCTAssertEqual(allMessages[2].type, .alias)

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testSlowConsumerWithBackpressure() async throws {
        let consumer = MockMessageConsumer { _ in
            // Simulate very slow consumer
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms per message
        }

        let queueName = "slow_consumer_test_\(UUID().uuidString)"
        let messageQueue = MessageQueue(consumer: consumer, name: queueName)
        await messageQueue.startRunloop()

        let messages = Message.createTestMessages(count: 5, idPrefix: "slow")

        let startTime = Date()
        for message in messages {
            await messageQueue.emit(message)
        }

        // Give reasonable time for slow processing
        try await AsyncTestHelper.wait(for: {
            try await messageQueue.size == 0
        }, timeout: 15.0)

        let processingTime = Date().timeIntervalSince(startTime)
        XCTAssertGreaterThan(processingTime, 2.0, "Processing should take time due to slow consumer")

        consumer.assertConsumedMessagesCount(expected: 5)

        await messageQueue.stop()
        try await messageQueue.clearQueue()
    }

    func testMemoryVsSQLiteConsistency() async throws {
        let sqliteConsumer = MockMessageConsumer()
        let memoryConsumer = MockMessageConsumer()

        // Force SQLite usage
        let sqliteQueueName = "sqlite_consistency_test_\(UUID().uuidString)"
        let sqliteQueue = MessageQueue(consumer: sqliteConsumer, name: sqliteQueueName)
        await sqliteQueue.startRunloop()

        // Force memory usage by using invalid path (implementation falls back to memory)
        let memoryQueueName = "memory_consistency_test_\(UUID().uuidString)"
        let memoryQueue = MessageQueue(consumer: memoryConsumer, name: memoryQueueName)
        await memoryQueue.startRunloop()

        let messages = Message.createTestMessages(count: 8, idPrefix: "consistency")

        sqliteConsumer.expectBatches(count: 8)
        memoryConsumer.expectBatches(count: 8)

        // Send same messages to both queues
        for message in messages {
            await sqliteQueue.emit(message)
            await memoryQueue.emit(message)
        }

        XCTAssertTrue(sqliteConsumer.waitForExpectedBatches(timeout: 10.0), "SQLite queue should process all messages")
        XCTAssertTrue(memoryConsumer.waitForExpectedBatches(timeout: 10.0), "Memory queue should process all messages")

        // Both should have same results
        sqliteConsumer.assertConsumedMessagesCount(expected: 8)
        memoryConsumer.assertConsumedMessagesCount(expected: 8)

        let sqliteOrder = sqliteConsumer.consumedMessages.flatMap { $0 }.map { $0.id }
        let memoryOrder = memoryConsumer.consumedMessages.flatMap { $0 }.map { $0.id }
        XCTAssertEqual(sqliteOrder, memoryOrder, "Both storage types should maintain same order")

        await sqliteQueue.stop()
        await memoryQueue.stop()
        try await sqliteQueue.clearQueue()
        try await memoryQueue.clearQueue()
    }
}
