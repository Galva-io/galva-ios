//
//  DurableProxyRequestStore.swift
//  Galva
//
//  Persistence for the durable `apiFetch` retry queue. Deliberately a
//  separate store (its own `galva-proxy.db`) from the batch-collect event
//  store: the two have different failure domains (a stuck proxy retry must
//  never back off the analytics pipeline) and different wire shapes
//  (1 request → 1 arbitrary endpoint, vs. N events → one batchCollect).
//
//  Mirrors the proven `MessageStorage` patterns — JSON-blob rows keyed by
//  id with a monotonic `created_at` for FIFO order, FIFO eviction for the
//  size cap, SQLite primary with an in-memory fallback when the disk path
//  can't be opened.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_PROXY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Storage backend for `DurableRequestQueue`. Actor-isolated so SQLite
/// access is serialized.
protocol DurableProxyRequestStore: Actor {
    func store(_ request: DurableProxyRequest) async throws
    func fetchOldest(limit: Int) async throws -> [DurableProxyRequest]
    func delete(_ ids: [String]) async throws
    func count() async throws -> Int
    @discardableResult
    func dropOldest(_ count: Int) async throws -> Int
    func clear() async throws
}

// MARK: - In-memory (fallback + tests)

/// Non-persistent backing. Used when SQLite can't open (degrades to
/// within-session retry only) and by unit tests.
actor InMemoryProxyRequestStore: DurableProxyRequestStore {
    private var rows: [DurableProxyRequest] = []

    init() {}

    func store(_ request: DurableProxyRequest) async throws {
        rows.append(request)
    }

    func fetchOldest(limit: Int) async throws -> [DurableProxyRequest] {
        Array(rows.sorted { $0.createdAt < $1.createdAt }.prefix(max(0, limit)))
    }

    func delete(_ ids: [String]) async throws {
        let set = Set(ids)
        rows.removeAll { set.contains($0.id) }
    }

    func count() async throws -> Int { rows.count }

    @discardableResult
    func dropOldest(_ count: Int) async throws -> Int {
        guard count > 0 else { return 0 }
        let ordered = rows.sorted { $0.createdAt < $1.createdAt }
        let victims = Set(ordered.prefix(count).map(\.id))
        rows.removeAll { victims.contains($0.id) }
        return victims.count
    }

    func clear() async throws { rows.removeAll() }
}

// MARK: - SQLite (primary)

/// SQLite-backed durable store. One row per request: id + JSON blob +
/// `created_at` for FIFO. Self-contained schema (no shared migrator) so the
/// event store's migration framework stays untouched.
actor SQLiteProxyRequestStore: DurableProxyRequestStore {
    nonisolated(unsafe) private var db: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: any GalvaLogger

    init(dbPath: String, logger: any GalvaLogger = NoOpLogger()) throws {
        self.logger = logger

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = ISO8601DateFormatter.galva.date(from: s) { return d }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let d = fallback.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid ISO 8601 date: \(s)"
            )
        }
        self.decoder = dec

        var tempDb: OpaquePointer?
        guard sqlite3_open(dbPath, &tempDb) == SQLITE_OK else {
            throw MessageStorageError.storageError("Unable to open proxy DB at path: \(dbPath)")
        }
        // Fresh, self-contained schema. `IF NOT EXISTS` makes open idempotent
        // across launches.
        let createSQL = """
        CREATE TABLE IF NOT EXISTS proxy_requests (
            id TEXT PRIMARY KEY,
            payload BLOB NOT NULL,
            created_at REAL NOT NULL DEFAULT (julianday('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_proxy_requests_created_at
            ON proxy_requests(created_at);
        """
        if sqlite3_exec(tempDb, createSQL, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(tempDb))
            sqlite3_close(tempDb)
            throw MessageStorageError.storageError("proxy schema create failed: \(msg)")
        }
        db = tempDb
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func store(_ request: DurableProxyRequest) async throws {
        let payload: Data
        do {
            payload = try encoder.encode(request)
        } catch {
            throw MessageStorageError.serializationError("Encode failed: \(error)")
        }
        let sql = "INSERT INTO proxy_requests (id, payload) VALUES (?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare proxy insert")
        }
        sqlite3_bind_text(stmt, 1, request.id, -1, SQLITE_TRANSIENT_PROXY)
        _ = payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(payload.count), SQLITE_TRANSIENT_PROXY)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MessageStorageError.storageError("Failed to insert proxy request: \(msg)")
        }
    }

    func fetchOldest(limit: Int) async throws -> [DurableProxyRequest] {
        let sql = "SELECT id, payload FROM proxy_requests ORDER BY created_at ASC LIMIT ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare proxy select")
        }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [DurableProxyRequest] = []
        var undecodable: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idCString = sqlite3_column_text(stmt, 0)
            let id = idCString.map { String(cString: $0) } ?? "<unknown>"
            let length = sqlite3_column_bytes(stmt, 1)
            guard length > 0, let bytes = sqlite3_column_blob(stmt, 1) else {
                undecodable.append(id)
                continue
            }
            let data = Data(bytes: bytes, count: Int(length))
            do {
                out.append(try decoder.decode(DurableProxyRequest.self, from: data))
            } catch {
                // Corrupt / future-shape row — drop it rather than wedge the
                // queue on a row we can't replay.
                logger.warning(.uploader, "dropping undecodable proxy request", metadata: [
                    "id": id,
                ], error: error)
                undecodable.append(id)
            }
        }
        if !undecodable.isEmpty { try await delete(undecodable) }
        return out
    }

    func delete(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "DELETE FROM proxy_requests WHERE id IN (\(placeholders));"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare proxy delete")
        }
        for (i, id) in ids.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT_PROXY)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MessageStorageError.storageError("Failed to delete proxy requests")
        }
    }

    func count() async throws -> Int {
        let sql = "SELECT COUNT(*) FROM proxy_requests;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare proxy count")
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    @discardableResult
    func dropOldest(_ count: Int) async throws -> Int {
        guard count > 0 else { return 0 }
        let sql = """
        DELETE FROM proxy_requests
        WHERE id IN (
            SELECT id FROM proxy_requests ORDER BY created_at ASC LIMIT ?
        );
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare proxy dropOldest")
        }
        sqlite3_bind_int(stmt, 1, Int32(count))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MessageStorageError.storageError("Failed to execute proxy dropOldest")
        }
        return Int(sqlite3_changes(db))
    }

    func clear() async throws {
        if sqlite3_exec(db, "DELETE FROM proxy_requests;", nil, nil, nil) != SQLITE_OK {
            throw MessageStorageError.storageError("Failed to clear proxy requests")
        }
    }
}
