//
//  DurableRequestQueue.swift
//  Galva
//
//  Guaranteed-delivery queue for `shouldRetry` apiFetch requests from the
//  in-app message bundle. The bundle fires and forgets; this queue makes
//  sure the request eventually reaches the Galva API — across network
//  outages and app launches.
//
//  Design (separate from the batch-collect MessageQueue, by intent):
//    • Durable: each request is persisted to `galva-proxy.db` before
//      `enqueue` returns, so it survives crashes / kills / cold starts.
//    • FIFO replay: oldest first, one request → one POST (no batching —
//      requests target arbitrary endpoints).
//    • Backoff: a transient failure (network down, 5xx, 408/429) keeps the
//      request and self-reschedules a retry with exponential jitter. A
//      permanent failure (other 4xx, malformed path) drops the request so
//      it can't wedge the queue.
//    • Bounded: a hard `maxStored` cap evicts the oldest (FIFO) so an
//      offline device can't grow the store without bound.
//    • Isolated failure domain: a stuck proxy retry never backs off the
//      analytics pipeline (that's the separate MessageQueue).
//
//  Drains on: enqueue, SDK configure (flush survivors from the last
//  launch), and every app foreground.
//

import Foundation

@GalvaActor
final class DurableRequestQueue {

    /// Outcome of a single replay attempt.
    private enum Outcome {
        /// 2xx — delivered, delete the record.
        case delivered
        /// Transient (network / 5xx / 408 / 429) — keep + retry after backoff.
        case retryable
        /// Permanent (other 4xx / malformed path) — drop the record + log.
        case permanent
    }

    private let store: any DurableProxyRequestStore
    private let client: APIClient
    private let logger: any GalvaLogger

    /// Hard cap on stored requests. Oldest evicted (FIFO) past this.
    private let maxStored: Int
    /// How many to attempt per drain pass before re-checking the store.
    private let drainBatch: Int

    /// Global consecutive-failure counter driving the backoff curve. Reset
    /// on any delivery / empty queue.
    private var consecutiveFailures = 0
    /// Reentrancy guard — one drain at a time.
    private var isDraining = false
    /// Pending backoff retry, scheduled after a transient failure.
    private var retryTask: Task<Void, Never>?
    /// Earliest time the next *network* attempt is allowed. Set while backing
    /// off after a transient failure. An unforced `drain()` (e.g. triggered by
    /// a burst of `enqueue`s) that arrives inside this window defers to the
    /// already-scheduled retry instead of attempting immediately — without
    /// this, every enqueue would cancel the backoff and hammer the network.
    /// A forced drain (foreground / launch / the scheduled retry itself)
    /// bypasses the window, since those are naturally rate-limited and a good
    /// moment to try sooner.
    private var nextAttemptAt: Date?

    init(
        store: any DurableProxyRequestStore,
        client: APIClient,
        logger: any GalvaLogger,
        maxStored: Int = 500,
        drainBatch: Int = 20
    ) {
        self.store = store
        self.client = client
        self.logger = logger
        self.maxStored = maxStored
        self.drainBatch = drainBatch
    }

    /// Convenience builder: SQLite under Application Support (excluded from
    /// iCloud backup), falling back to in-memory if the disk path can't be
    /// opened — same robustness posture as the event queue.
    static func makeDefault(client: APIClient, logger: any GalvaLogger) -> DurableRequestQueue {
        let store: any DurableProxyRequestStore
        do {
            let url = try defaultStorageURL()
            try? markExcludedFromBackup(url)
            store = try SQLiteProxyRequestStore(dbPath: url.path, logger: logger)
        } catch {
            logger.warning(.uploader,
                           "durable proxy store on disk unavailable — using in-memory (no cross-launch retry)",
                           error: error)
            store = InMemoryProxyRequestStore()
        }
        return DurableRequestQueue(store: store, client: client, logger: logger)
    }

    // MARK: - Public

    /// Persist a fire-and-forget request and kick off delivery. Returns once
    /// the request is durably stored (not once it's delivered) — the caller
    /// (bridge) acks the bundle immediately.
    func enqueue(path: String, method: String, body: Data?, headers: [String: String]) async {
        let request = DurableProxyRequest(path: path, method: method, body: body, headers: headers)
        do {
            try await store.store(request)
            await enforceCap()
            logger.debug(.uploader, "durable proxy enqueued", metadata: [
                "id": request.id,
                "method": method,
                "path": path,
            ])
            await drain()
        } catch {
            // Couldn't even persist — log; nothing else we can do without
            // risking an unbounded in-memory backlog.
            logger.error(.uploader, "durable proxy enqueue failed to persist", metadata: [
                "method": method,
                "path": path,
            ], error: error)
        }
    }

    /// Attempt to deliver pending requests, oldest first. The reentrancy
    /// guard collapses overlapping calls.
    ///
    /// - Parameter force: When `false` (the default — used by `enqueue`),
    ///   the call respects the active backoff window: if we're still waiting
    ///   out a transient failure, it returns without touching the network and
    ///   lets the scheduled retry fire. When `true` (foreground, launch, and
    ///   the scheduled retry itself), it bypasses the window and attempts now.
    func drain(force: Bool = false) async {
        guard !isDraining else { return }
        // Respect the backoff window for unforced drains so a burst of
        // enqueues can't hammer the network — the scheduled retry owns the
        // next attempt.
        if !force, let next = nextAttemptAt, Date() < next {
            logger.debug(.uploader, "durable proxy drain deferred (backing off)", metadata: [
                "secondsRemaining": String(format: "%.2f", next.timeIntervalSinceNow),
            ])
            return
        }
        isDraining = true
        defer { isDraining = false }
        // We're attempting now — supersede any scheduled retry.
        retryTask?.cancel()
        retryTask = nil

        while true {
            let batch: [DurableProxyRequest]
            do {
                batch = try await store.fetchOldest(limit: drainBatch)
            } catch {
                logger.error(.uploader, "durable proxy fetch failed", error: error)
                scheduleRetry()
                return
            }
            if batch.isEmpty {
                resetBackoff()
                return
            }

            for request in batch {
                switch await replay(request) {
                case .delivered:
                    try? await store.delete([request.id])
                    resetBackoff()
                    logger.debug(.uploader, "durable proxy delivered", metadata: ["id": request.id])
                case .permanent:
                    try? await store.delete([request.id])
                    resetBackoff()
                    logger.warning(.uploader, "durable proxy dropped (permanent failure)", metadata: [
                        "id": request.id,
                        "method": request.method,
                        "path": request.path,
                    ])
                case .retryable:
                    // Stop on the first transient failure — preserves FIFO
                    // order and gives the network time to recover before the
                    // next attempt (scheduled with exponential backoff).
                    scheduleRetry()
                    return
                }
            }
            // Whole batch handled (delivered / dropped) — loop to see if more
            // requests are waiting beyond `drainBatch`.
        }
    }

    /// Number of requests currently awaiting delivery (diagnostics / tests).
    var pendingCount: Int {
        get async { (try? await store.count()) ?? 0 }
    }

    // MARK: - Internals

    private func replay(_ request: DurableProxyRequest) async -> Outcome {
        do {
            let response = try await client.proxyRequest(
                path: request.path,
                method: request.method,
                body: request.body,
                additionalHeaders: request.headers
            )
            if (200..<300).contains(response.status) { return .delivered }
            return Self.isRetryable(status: response.status) ? .retryable : .permanent
        } catch let error as APIError {
            switch error {
            case .malformedURL, .decoding:
                // Bad path or un-encodable — will never succeed; drop.
                return .permanent
            case .invalidResponse, .transport:
                // Network down / DNS / TLS — the "network lost" case the
                // queue exists for. Keep + retry.
                return .retryable
            case .http(let status, _):
                return Self.isRetryable(status: status) ? .retryable : .permanent
            }
        } catch {
            return .retryable
        }
    }

    /// 408 / 429 / 5xx are transient; other non-2xx are permanent.
    private static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500..<600).contains(status)
    }

    /// Schedule the next delivery attempt with exponential backoff + jitter
    /// (`Backoff`, capped at 60s). Records `nextAttemptAt` so unforced drains
    /// in the meantime defer instead of hammering, and arms a one-shot task
    /// that forces a drain when the window elapses.
    private func scheduleRetry() {
        consecutiveFailures += 1
        let delay = Backoff.delay(forAttempt: consecutiveFailures)
        nextAttemptAt = Date().addingTimeInterval(delay)
        logger.warning(.uploader, "durable proxy retry scheduled", metadata: [
            "consecutiveFailures": String(consecutiveFailures),
            "backoffSeconds": String(format: "%.2f", delay),
        ])
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            // Forced: the backoff window has elapsed, so attempt regardless.
            await self?.drain(force: true)
        }
    }

    /// Clear the backoff state after progress (a delivery, a permanent drop,
    /// or an empty queue) so the next failure starts the curve fresh.
    private func resetBackoff() {
        consecutiveFailures = 0
        nextAttemptAt = nil
    }

    private func enforceCap() async {
        guard maxStored > 0 else { return }
        do {
            let current = try await store.count()
            guard current > maxStored else { return }
            let dropped = try await store.dropOldest(current - maxStored)
            logger.warning(.uploader, "durable proxy cap exceeded — dropped oldest", metadata: [
                "cap": String(maxStored),
                "dropped": String(dropped),
            ])
        } catch {
            logger.error(.uploader, "durable proxy cap enforcement failed", error: error)
        }
    }

    // MARK: - Storage location (Application Support, excluded from backup)

    private nonisolated static func defaultStorageURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Galva", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("galva-proxy.db")
    }

    private nonisolated static func markExcludedFromBackup(_ url: URL) throws {
        var dir = url.deletingLastPathComponent()
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
    }
}
