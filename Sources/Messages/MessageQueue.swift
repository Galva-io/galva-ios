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

    /// Reentrancy guard. `processAllMessages` awaits the consumer, which is a
    /// suspension point — without this flag another `emit` arriving during
    /// the await could start a parallel drain that fetches the same not-yet-
    /// deleted batch and delivers it twice.
    private var isProcessing: Bool = false

    /// Designated initializer — caller supplies the storage backend.
    /// `nonisolated` so non-actor code (notably tests) can construct a queue;
    /// the body only writes stored properties and doesn't touch shared state.
    nonisolated init(
        consumer: any MessageConsumer,
        storage: any MessageStorage,
        options: QueueOptions? = nil,
        logger: any GalvaLogger = OSLogLogger()
    ) {
        self.consumer = consumer
        self.storage = storage
        self.options = options
        self.logger = logger
    }

    /// Convenience initializer — picks SQLite under the app's Documents
    /// directory using `name` as the file stem; falls back to in-memory if
    /// SQLite fails to open. Production callers use this; tests inject a
    /// storage explicitly via the designated initializer.
    nonisolated convenience init(
        consumer: any MessageConsumer,
        options: QueueOptions? = nil,
        name: String? = nil,
        logger: any GalvaLogger = OSLogLogger()
    ) {
        let storage = Self.defaultStorage(name: name ?? "__DEFAULT", logger: logger)
        self.init(consumer: consumer, storage: storage, options: options, logger: logger)
    }

    private nonisolated static func defaultStorage(
        name: String,
        logger: any GalvaLogger
    ) -> any MessageStorage {
        do {
            let containerPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
                ?? NSTemporaryDirectory()
            let dbFileURL = URL(fileURLWithPath: containerPath).appendingPathComponent("galva-\(name).db")
            return try SQLiteMessageStorage(dbPath: dbFileURL.path)
        } catch {
            logger.warning(.storage, "SQLite open failed, falling back to in-memory storage", error: error)
            return InMemoryMessageStorage()
        }
    }

    func emit(_ message: Message) async {
        logger.debug(.queue, "emit", metadata: [
            "type": String(describing: message.body.wireType),
            "messageId": message.id,
        ])
        do {
            // Store message sequentially to guarantee FIFO order
            try await storage.storeMessage(message)

            // Trigger processing based on options
            await triggerProcessingIfNeeded()
        } catch {
            logger.error(.queue, "failed to store message", error: error)
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
        // Allow restart from `.idle` or `.stopped`. Re-entry while already
        // `.processing` is a no-op.
        guard state != .processing else { return }
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
                logger.warning(.queue, "failed to check queue size", error: error)
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
        // Reentrancy guard — only one drain at a time. A concurrent caller
        // exits early because the in-flight drain will pick up any newly
        // emitted messages in its own loop.
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

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
                logger.debug(.queue, "draining batch", metadata: ["size": String(messages.count)])
                do {
                    try await consumer.consume(messages: messages)

                    // Remove processed messages only on success
                    try await storage.deleteMessages(messages.map { $0.id })
                    consecutiveFailures = 0
                    logger.debug(.queue, "batch acknowledged", metadata: ["size": String(messages.count)])
                } catch {
                    consecutiveFailures += 1
                    let delay = Backoff.delay(forAttempt: consecutiveFailures)
                    logger.warning(.queue, "consumer failed; retaining batch and backing off",
                                   metadata: [
                                       "batchSize": String(messages.count),
                                       "consecutiveFailures": String(consecutiveFailures),
                                       "backoffSeconds": String(format: "%.2f", delay),
                                   ],
                                   error: error)
                    // Don't delete messages on failure - they remain in queue for retry.
                    // Exponential backoff with jitter to avoid hammering on outage.
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    break // Stop processing this batch, batch timer will resume.
                }

            } catch {
                consecutiveFailures += 1
                let delay = Backoff.delay(forAttempt: consecutiveFailures)
                logger.error(.storage, "failed to fetch messages",
                             metadata: [
                                 "consecutiveFailures": String(consecutiveFailures),
                                 "backoffSeconds": String(format: "%.2f", delay),
                             ],
                             error: error)
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
