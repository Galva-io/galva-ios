//
//  MessageQueueConcurrencyTests.swift
//  GalvaTests
//
//  Covers concurrent producer scenarios — the queue must not drop, dedup,
//  or reorder writes coming from independent producers.
//

import Foundation
@testable import Galva
import XCTest

final class MessageQueueConcurrencyTests: XCTestCase {

    func test_concurrentProducers_noWritesLost() async throws {
        let consumer = RecordingConsumer()
        let storage = TestStorage.memory()
        let queue = MessageQueue(
            consumer: consumer,
            storage: storage,
            options: .init(batchingWindow: .init(timeWindow: 0.1, maxCount: 50))
        )
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        let producerCount = 8
        let perProducer = 25
        let total = producerCount * perProducer

        await withTaskGroup(of: Void.self) { group in
            for producer in 0 ..< producerCount {
                group.addTask {
                    for i in 0 ..< perProducer {
                        await queue.emit(.makeTrack(event: "p\(producer)-m\(i)"))
                    }
                }
            }
        }

        await waitForMessages(consumer, count: total, timeout: 5.0)
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0)

        let events = await consumer.consumedEvents
        XCTAssertEqual(events.count, total)
        XCTAssertEqual(Set(events).count, total, "No duplicates expected")
    }

    func test_multipleQueues_areIsolated() async throws {
        let consumerA = RecordingConsumer()
        let consumerB = RecordingConsumer()
        let queueA = MessageQueue(consumer: consumerA, storage: TestStorage.memory())
        let queueB = MessageQueue(consumer: consumerB, storage: TestStorage.memory())
        await queueA.startRunloop()
        await queueB.startRunloop()
        defer {
            Task { await queueA.stop() }
            Task { await queueB.stop() }
        }

        await queueA.emit(.makeTrack(event: "a-1"))
        await queueA.emit(.makeTrack(event: "a-2"))
        await queueB.emit(.makeTrack(event: "b-1"))

        await waitForMessages(consumerA, count: 2)
        await waitForMessages(consumerB, count: 1)

        let aEvents = await consumerA.consumedEvents
        let bEvents = await consumerB.consumedEvents
        XCTAssertEqual(aEvents, ["a-1", "a-2"])
        XCTAssertEqual(bEvents, ["b-1"])
    }

    func test_slowConsumer_doesNotLoseMessages() async throws {
        // A slow consumer should still receive every emitted message,
        // eventually. We don't pin timing.
        let consumer = RecordingConsumer()
        await consumer.setBeforeConsume { _ in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms per batch
        }

        let queue = MessageQueue(consumer: consumer, storage: TestStorage.memory())
        await queue.startRunloop()
        defer { Task { await queue.stop() } }

        for msg in Message.sequence(prefix: "slow", count: 10) {
            await queue.emit(msg)
        }

        await waitForMessages(consumer, count: 10, timeout: 5.0)
        let events = await consumer.consumedEvents
        XCTAssertEqual(events, (0 ..< 10).map { "slow-\(String(format: "%03d", $0))" })
    }
}
