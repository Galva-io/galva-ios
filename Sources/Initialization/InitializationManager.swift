//
//  InitializationManager.swift
//  Galva
//
//  Owns the /sdk/initialize lifecycle.
//
//  ┌────────────────────────────────────────────────────────────────────────┐
//  │  Two-phase startup                                                      │
//  │                                                                         │
//  │   1. `loadCached()` — synchronous on configure(). If a prior session   │
//  │      persisted a response, surface it immediately so the rest of the   │
//  │      SDK (in-app messaging, queue flush window) has live data without  │
//  │      waiting for the network.                                          │
//  │                                                                         │
//  │   2. `refresh()` — fires asynchronously after configure(). POSTs       │
//  │      /sdk/initialize, persists the response, swaps the in-memory copy. │
//  │      On failure, the cached copy stays in place.                       │
//  │                                                                         │
//  │  This gives us: instant in-app messaging on cold start (cached data),  │
//  │  best-effort refresh of webview versions / batch tuning (network),     │
//  │  and full offline resilience (cache survives indefinitely).            │
//  └────────────────────────────────────────────────────────────────────────┘
//

import Foundation

@GalvaActor
final class InitializationManager {

    private let client: APIClient
    private let cache: InitializationCache?
    private let logger: any GalvaLogger

    /// Last-known-good initialization data — either loaded from disk on
    /// startup or returned by a successful refresh. `nil` only when we've
    /// never successfully initialized AND have no cache (e.g. truly first
    /// launch and the network is unreachable).
    private(set) var current: InitializationData?

    init(
        client: APIClient,
        cache: InitializationCache?,
        logger: any GalvaLogger
    ) {
        self.client = client
        self.cache = cache
        self.logger = logger
    }

    // MARK: - Public lifecycle

    /// Read the cached initialization data into memory, if any. Cheap; safe
    /// to call from configure() before kicking off a network refresh.
    func loadCached() {
        guard let cache, let cached = cache.load() else {
            logger.debug(.configuration, "init cache miss")
            return
        }
        self.current = cached
        logger.info(.configuration, "init data loaded from cache", metadata: [
            "webviewVersions": String(cached.webviewVersions.count),
            "storekitProductIds": String(cached.storekitProductIds.count),
        ])
    }

    /// Hit POST /sdk/initialize. On success, persist + swap. On failure,
    /// leave the cached value (if any) in place and log.
    func refresh() async {
        let body = InitializeRequest(bridgeProtocolVersion: SDKConstants.bridgeProtocolVersion)
        do {
            let response: InitializeResponse = try await client.post(
                path: SDKConstants.sdkInitializePath,
                body: body
            )
            self.current = response.data
            if let cache {
                do {
                    try cache.save(response.data)
                } catch {
                    logger.warning(.configuration, "failed to persist init cache", error: error)
                }
            }
            logger.info(.configuration, "init data refreshed", metadata: [
                "webviewVersions": String(response.data.webviewVersions.count),
                "storekitProductIds": String(response.data.storekitProductIds.count),
                "flushSize": String(Int(response.data.batchCollection.flushSize)),
                "flushIntervalMs": String(Int(response.data.batchCollection.flushIntervalMs)),
            ])
        } catch let error as APIError {
            logger.warning(.configuration, "init refresh failed — keeping cached data",
                           metadata: ["retryable": String(error.isRetryable)],
                           error: error)
        } catch {
            logger.warning(.configuration, "init refresh failed (unexpected)", error: error)
        }
    }
}
