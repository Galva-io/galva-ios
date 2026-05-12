//
//  MessageQueue.swift
//  Galva
//
//  Created by Peter Vu on 11/9/25.
//

import Foundation

protocol MessageConsumer: Sendable {
    func consume(messages: [Message]) async throws
}

@GalvaActor
class MessageQueue {
    struct QueueOptions {
        struct BatchingWindow {
            var timeWindow: TimeInterval
            var maxCount: Int
        }

        var batchingWindow: BatchingWindow?
    }

    enum State {
        case idle
        case processing
        case stopped
    }

    private let storage: any MessageStorage
    private let consumer: any MessageConsumer
    private let options: QueueOptions?
    private var state: State = .idle
    private var processingTask: Task<Void, Never>?

    init(consumer: any MessageConsumer, options: QueueOptions? = nil, name: String? = nil) {
        self.consumer = consumer
        self.options = options
        let queueName = name ?? "__DEFAULT"

        do {
            let containerPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
            let dbFileURL = URL(fileURLWithPath: containerPath).appendingPathExtension("\(queueName).db")
            storage = try SQLiteMessageStorage(dbPath: dbFileURL.path)
        } catch {
            storage = InMemoryMessageStorage()
        }
    }

    func emit(_ message: Message) async {
        do {
            // Store message sequentially to guarantee FIFO order
            try await storage.storeMessage(message)

            // Trigger processing based on options
            await triggerProcessingIfNeeded()
        } catch {
            print("ERROR: Failed to store message: \(error)")
        }
    }

    var size: Int {
        get async throws {
            try await storage.getQueueSize()
        }
    }

    func clearQueue() async throws {
        processingTask?.cancel()
        try await storage.clearQueue()
    }

    deinit {
        processingTask?.cancel()
    }

    func startRunloop() async {
        guard state == .idle else { return }
        state = .processing

        // Process any existing messages immediately
        await processAllMessages()

        // Start continuous processing if batching is configured
        if let batchingWindow = options?.batchingWindow {
            startBatchTimer(window: batchingWindow)
        }
    }

    private func triggerProcessingIfNeeded() async {
        guard state == .processing else { return }

        if let batchingWindow = options?.batchingWindow {
            // Check if we should process due to batch size
            do {
                let queueSize = try await storage.getQueueSize()
                if queueSize >= batchingWindow.maxCount {
                    await processAllMessages()
                }
            } catch {
                print("Failed to check queue size: \(error)")
                // Continue anyway - processAllMessages will handle errors
                await processAllMessages()
            }
        } else {
            // No batching - process immediately
            await processAllMessages()
        }
    }

    private func startBatchTimer(window: QueueOptions.BatchingWindow) {
        processingTask?.cancel()
        processingTask = Task {
            while !Task.isCancelled && state == .processing {
                do {
                    try await Task.sleep(nanoseconds: UInt64(window.timeWindow * 1_000_000_000))
                    if !Task.isCancelled && state == .processing {
                        await processAllMessages()
                    }
                } catch {
                    // Task was cancelled - exit gracefully
                    break
                }
            }
        }
    }

    private func processAllMessages() async {
        guard state == .processing else { return }

        while state == .processing {
            do {
                let batchSize = options?.batchingWindow?.maxCount ?? 100
                let messages = try await storage.fetchMessages(limit: batchSize)

                if messages.isEmpty {
                    break // No more messages
                }

                // Process messages
                do {
                    try await consumer.consume(messages: messages)

                    // Remove processed messages only on success
                    try await storage.deleteMessages(messages.map { $0.id })
                } catch {
                    print("Failed to process messages: \(error)")
                    // Don't delete messages on failure - they remain in queue for retry
                    // Wait a bit before next attempt to avoid tight loop
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms backoff
                    break // Stop processing this batch, but continue later
                }

            } catch {
                print("Failed to fetch messages: \(error)")
                // Storage error - wait longer before retry
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms backoff
                break
            }
        }
    }

    func stop() async {
        state = .stopped
        processingTask?.cancel()
        processingTask = nil
    }
}
