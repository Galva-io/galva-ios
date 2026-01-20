//
//  MessageQueueInMemoryTests.swift
//  GalvaTests
//
//  Created by Claude Code on 11/9/25.
//

import Foundation
@testable import Galva
import XCTest

class MessageQueueInMemoryTests: XCTestCase, @unchecked Sendable {
    private var inMemoryStorage: InMemoryMessageStorage!

    override func setUp() async throws {
        try await super.setUp()
        inMemoryStorage = InMemoryMessageStorage()
    }

    override func tearDown() async throws {
        inMemoryStorage = nil
        try await super.tearDown()
    }

    func testStoreAndFetchSingleMessage() async throws {
        let testMessage = Message.createTestMessage(id: "memory-test-1")

        try await inMemoryStorage.storeMessage(testMessage)

        let fetchedMessages = try await inMemoryStorage.fetchMessages(limit: 10)
        XCTAssertEqual(fetchedMessages.count, 1)
        XCTAssertEqual(fetchedMessages[0].id, "memory-test-1")

        let queueSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(queueSize, 1)
    }

    func testStoreAndFetchMultipleMessages() async throws {
        let messages = Message.createTestMessages(count: 5, idPrefix: "mem-multi")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let queueSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(queueSize, 5)

        let fetchedMessages = try await inMemoryStorage.fetchMessages(limit: 10)
        XCTAssertEqual(fetchedMessages.count, 5)

        // Verify FIFO order
        let expectedIds = ["mem-multi_000", "mem-multi_001", "mem-multi_002", "mem-multi_003", "mem-multi_004"]
        let actualIds = fetchedMessages.map { $0.id }
        XCTAssertEqual(actualIds, expectedIds)
    }

    func testFetchWithLimit() async throws {
        let messages = Message.createTestMessages(count: 10, idPrefix: "mem-limit")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let firstBatch = try await inMemoryStorage.fetchMessages(limit: 3)
        XCTAssertEqual(firstBatch.count, 3)

        let expectedFirstBatch = ["mem-limit_000", "mem-limit_001", "mem-limit_002"]
        let actualFirstBatch = firstBatch.map { $0.id }
        XCTAssertEqual(actualFirstBatch, expectedFirstBatch)

        let secondBatch = try await inMemoryStorage.fetchMessages(limit: 5)
        XCTAssertEqual(secondBatch.count, 5)

        let expectedSecondBatch = ["mem-limit_000", "mem-limit_001", "mem-limit_002", "mem-limit_003", "mem-limit_004"]
        let actualSecondBatch = secondBatch.map { $0.id }
        XCTAssertEqual(actualSecondBatch, expectedSecondBatch)
    }

    func testDeleteMessages() async throws {
        let messages = Message.createTestMessages(count: 5, idPrefix: "mem-delete")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let initialSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(initialSize, 5)

        // Delete first 2 messages
        let idsToDelete = ["mem-delete_000", "mem-delete_001"]
        try await inMemoryStorage.deleteMessages(idsToDelete)

        let sizeAfterDelete = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(sizeAfterDelete, 3)

        let remainingMessages = try await inMemoryStorage.fetchMessages(limit: 10)
        let remainingIds = remainingMessages.map { $0.id }
        let expectedRemainingIds = ["mem-delete_002", "mem-delete_003", "mem-delete_004"]
        XCTAssertEqual(remainingIds, expectedRemainingIds)
    }

    func testDeleteNonExistentMessages() async throws {
        let messages = Message.createTestMessages(count: 3, idPrefix: "mem-nonexist")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let initialSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(initialSize, 3)

        // Try to delete non-existent messages
        let nonExistentIds = ["fake_001", "fake_002"]
        try await inMemoryStorage.deleteMessages(nonExistentIds)

        let sizeAfterDelete = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(sizeAfterDelete, 3) // Size should remain unchanged
    }

    func testDeleteEmptyArray() async throws {
        let messages = Message.createTestMessages(count: 2, idPrefix: "mem-empty")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let initialSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(initialSize, 2)

        // Delete empty array - should not affect anything
        try await inMemoryStorage.deleteMessages([])

        let sizeAfterDelete = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(sizeAfterDelete, 2)
    }

    func testClearQueue() async throws {
        let messages = Message.createTestMessages(count: 10, idPrefix: "mem-clear")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let initialSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(initialSize, 10)

        try await inMemoryStorage.clearQueue()

        let sizeAfterClear = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(sizeAfterClear, 0)

        let remainingMessages = try await inMemoryStorage.fetchMessages(limit: 10)
        XCTAssertTrue(remainingMessages.isEmpty)
    }

    func testMessageFieldsPreservation() async throws {
        let testMessage = Message.createTestMessage(
            id: "mem-field-test",
            type: .identify,
            userId: "mem-test-user-id",
            anonymousId: "mem-test-anon-id",
            event: "mem_identify_event",
            properties: [
                "string_prop": "mem_test_string",
                "int_prop": 456,
                "double_prop": 78.91,
                "bool_prop": false,
            ]
        )

        try await inMemoryStorage.storeMessage(testMessage)

        let fetchedMessages = try await inMemoryStorage.fetchMessages(limit: 1)
        XCTAssertEqual(fetchedMessages.count, 1)

        let fetched = fetchedMessages[0]
        XCTAssertEqual(fetched.id, "mem-field-test")
        XCTAssertEqual(fetched.type, .identify)
        XCTAssertEqual(fetched.userId, "mem-test-user-id")
        XCTAssertEqual(fetched.anonymousId, "mem-test-anon-id")
        XCTAssertEqual(fetched.event, "mem_identify_event")
        XCTAssertNotNil(fetched.properties)

        // In memory storage should preserve all fields exactly
        XCTAssertEqual(fetched.timestamp, testMessage.timestamp)
        XCTAssertEqual(fetched.context.app.name, testMessage.context.app.name)
    }

    func testConcurrentOperations() async throws {
        let messages = Message.createTestMessages(count: 20, idPrefix: "mem-concurrent")

        // Store messages concurrently
        await withTaskGroup(of: Void.self) { group in
            for message in messages {
                group.addTask { [self] in
                    try? await inMemoryStorage.storeMessage(message)
                }
            }
        }

        let finalSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(finalSize, 20, "All messages should be stored despite concurrent access")

        // Fetch all messages and verify they're all present
        let fetchedMessages = try await inMemoryStorage.fetchMessages(limit: 20)
        XCTAssertEqual(fetchedMessages.count, 20)

        let sortedIds = fetchedMessages.map { $0.id }.sorted()
        let expectedIds = (0 ..< 20).map { "mem-concurrent_\(String(format: "%03d", $0))" }.sorted()
        XCTAssertEqual(sortedIds, expectedIds)
    }

    func testMemoryEfficiency() async throws {
        // Test that in-memory storage handles reasonably large numbers of messages
        let messages = Message.createTestMessages(count: 1000, idPrefix: "mem-large")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        let queueSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(queueSize, 1000)

        // Test fetching in batches
        let firstBatch = try await inMemoryStorage.fetchMessages(limit: 100)
        XCTAssertEqual(firstBatch.count, 100)

        // Verify order is maintained
        let firstBatchIds = firstBatch.map { $0.id }
        let expectedFirstBatch = (0 ..< 100).map { "mem-large_\(String(format: "%03d", $0))" }
        XCTAssertEqual(firstBatchIds, expectedFirstBatch)

        // Delete first batch
        let idsToDelete = firstBatch.map { $0.id }
        try await inMemoryStorage.deleteMessages(idsToDelete)

        let remainingSize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(remainingSize, 900)

        // Verify remaining messages start from the correct index
        let remainingMessages = try await inMemoryStorage.fetchMessages(limit: 10)
        let remainingIds = remainingMessages.map { $0.id }
        let expectedRemainingStart = (100 ..< 110).map { "mem-large_\(String(format: "%03d", $0))" }
        XCTAssertEqual(remainingIds, expectedRemainingStart)
    }

    func testOrderPreservationWithDeletes() async throws {
        let messages = Message.createTestMessages(count: 10, idPrefix: "mem-order")

        for message in messages {
            try await inMemoryStorage.storeMessage(message)
        }

        // Delete messages from the middle
        let idsToDelete = ["mem-order_002", "mem-order_005", "mem-order_007"]
        try await inMemoryStorage.deleteMessages(idsToDelete)

        let remainingMessages = try await inMemoryStorage.fetchMessages(limit: 10)
        let remainingIds = remainingMessages.map { $0.id }

        let expectedRemaining = ["mem-order_000", "mem-order_001", "mem-order_003", "mem-order_004", "mem-order_006", "mem-order_008", "mem-order_009"]
        XCTAssertEqual(remainingIds, expectedRemaining, "Order should be preserved after selective deletions")
    }

    func testEmptyStorageOperations() async throws {
        // Test operations on empty storage
        let emptySize = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(emptySize, 0)

        let emptyFetch = try await inMemoryStorage.fetchMessages(limit: 10)
        XCTAssertTrue(emptyFetch.isEmpty)

        // Delete from empty storage should not cause issues
        try await inMemoryStorage.deleteMessages(["non-existent"])

        let stillEmpty = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(stillEmpty, 0)

        // Clear empty storage should not cause issues
        try await inMemoryStorage.clearQueue()

        let stillEmptyAfterClear = try await inMemoryStorage.getQueueSize()
        XCTAssertEqual(stillEmptyAfterClear, 0)
    }
}
