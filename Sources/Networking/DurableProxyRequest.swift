//
//  DurableProxyRequest.swift
//  Galva
//
//  Persisted record for a `shouldRetry` apiFetch — a fire-and-forget HTTP
//  request the hosted in-app message bundle hands to the SDK with a
//  guarantee of eventual delivery. Unlike a normal `apiFetch` (which the
//  bundle awaits inline), a durable request is queued, survives app kills,
//  and is retried until it lands.
//
//  Stored as a JSON blob in `galva-proxy.db` (see SQLiteProxyRequestStore),
//  separate from the batch-collect event store so a flaky proxy retry can
//  never stall the analytics pipeline.
//

import Foundation

/// A single retryable proxy request awaiting delivery to the Galva API.
/// `body` rides as base64 in JSON (Foundation's default `Data` encoding),
/// so arbitrary payloads round-trip losslessly across launches.
struct DurableProxyRequest: Sendable, Codable, Hashable {
    /// Stable record id (UUIDv7, lowercased) — FIFO-ish by creation and the
    /// delete key once delivered.
    let id: String
    /// Relative API path (same-origin enforced at replay time by APIClient).
    let path: String
    /// HTTP method (already validated / upper-cased by the bridge).
    let method: String
    /// Pre-serialized request body, or `nil`.
    let body: Data?
    /// Caller-supplied headers (auth headers are injected at replay time and
    /// can't be overridden here).
    let headers: [String: String]
    /// When the bundle enqueued it. FIFO ordering + diagnostics.
    let createdAt: Date

    init(
        id: String = UUIDv7.next().uuidString.lowercased(),
        path: String,
        method: String,
        body: Data?,
        headers: [String: String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.method = method
        self.body = body
        self.headers = headers
        self.createdAt = createdAt
    }
}
