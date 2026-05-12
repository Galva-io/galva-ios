//
//  MessageQueue.swift
//  Galva
//
//  Persistent FIFO message queue with batching, single-consumer dispatch,
//  and exponential backoff on failure.
//
//  Storage: SQLite via SQLiteMessageStorage (falls back to InMemory on
//  filesystem failure). Each `emit` is durable before returning — events
//  survive crashes and kills.
//
//  Batching:
//    • Time-based: every `timeWindow` seconds the queue drains.
//    • Size-based: when queue size hits `maxCount` it drains immediately.
//    • Per-batch cap: server allows max 100 messages per request.
//
//  Failure handling:
//    • Consumer throws → batch retained, exponential backoff (jittered),
//      timer resumes processing.
//    • Storage fails → same backoff.
//    • Consumer returns successfully → batch deleted from storage.
//

import Foundation

/// Sink for batches drained from the queue. Implemented by `UploadConsumer`
/// to bridge into the HTTP uploader.
///
/// Throwing from `consume` signals a retryable failure — the queue keeps
/// the batch and retries after backoff. Returning normally signals "handled"
/// (success or permanent-drop), and the batch is deleted.
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
    private let logger: any GalvaLogger
    private var state: State = .idle
    private var processingTask: Task<Void, Never>?
    private var consecutiveFailures: Int = 0

    init(
        consumer: any MessageConsumer,
        options: QueueOptions? = nil,
        name: String? = nil,
        logger: any GalvaLogger = GalvaConsoleLogger()
    ) {
        self.consumer = consumer
        self.options = options
        self.logger = logger
        let queueName = name ?? "__DEFAULT"

        do {
            let containerPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? NSTemporaryDirectory()
            let dbFileURL = URL(fileURLWithPath: containerPath).appendingPathComponent("galva-\(queueName).db")
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
            logger.log(.error, message: "Failed to store message", error: error)
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
                logger.log(.warning, message: "Failed to check queue size", error: error)
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
                // Cap batch size at server limit (max 100 per spec).
                let configured = options?.batchingWindow?.maxCount ?? SDKConstants.maxBatchSize
                let batchSize = min(configured, SDKConstants.maxBatchSize)
                let messages = try await storage.fetchMessages(limit: batchSize)

                if messages.isEmpty {
                    consecutiveFailures = 0
                    break // No more messages
                }

                // Process messages
                do {
                    try await consumer.consume(messages: messages)

                    // Remove processed messages only on success
                    try await storage.deleteMessages(messages.map { $0.id })
                    consecutiveFailures = 0
                } catch {
                    logger.log(.warning, message: "Failed to process messages", error: error)
                    // Don't delete messages on failure - they remain in queue for retry.
                    // Exponential backoff with jitter to avoid hammering on outage.
                    consecutiveFailures += 1
                    let delay = Backoff.delay(forAttempt: consecutiveFailures)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    break // Stop processing this batch, batch timer will resume.
                }

            } catch {
                logger.log(.error, message: "Failed to fetch messages", error: error)
                consecutiveFailures += 1
                let delay = Backoff.delay(forAttempt: consecutiveFailures)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
