//
//  MessageQueue+SQLite.swift
//  Galva
//
//  SQLite-backed message store. Each row is a single message serialized as a
//  JSON blob (the wire format), plus a monotonic `created_at` for FIFO order.
//  Storing the raw wire format keeps schema migrations cheap when new
//  message types are added.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor SQLiteMessageStorage: MessageStorage {
    /// `nonisolated(unsafe)` so the nonisolated deinit can close the handle.
    /// All other access goes through actor-isolated methods, which serialize
    /// SQLite calls correctly.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let dbPath: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logger: any GalvaLogger

    init(dbPath: String, logger: any GalvaLogger = NoOpLogger()) throws {
        self.dbPath = dbPath
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
            // Fallback: bare ISO 8601 without fractional seconds.
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let d = fallback.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid ISO 8601 date: \(s)"
            )
        }
        self.decoder = dec

        var tempDb: OpaquePointer?
        if sqlite3_open(dbPath, &tempDb) != SQLITE_OK {
            throw MessageStorageError.storageError("Unable to open database at path: \(dbPath)")
        }

        // Schema migrations live in StorageMigrator. On downgrade (DB is
        // newer than this SDK), it throws — we close the handle and let
        // the caller fall back to in-memory storage, leaving the on-disk
        // data untouched for the next forward upgrade.
        do {
            try StorageMigrator.migrate(tempDb, logger: logger)
        } catch {
            sqlite3_close(tempDb)
            throw error
        }
        db = tempDb
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func storeMessage(_ message: Message) async throws {
        let payload: Data
        do {
            payload = try encoder.encode(message)
        } catch {
            throw MessageStorageError.serializationError("Encode failed: \(error)")
        }

        let insertSQL = "INSERT INTO messages (id, payload) VALUES (?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare insert statement")
        }

        sqlite3_bind_text(stmt, 1, message.id, -1, SQLITE_TRANSIENT)
        _ = payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MessageStorageError.storageError("Failed to insert message: \(msg)")
        }
    }

    func fetchMessages(limit: Int) async throws -> [Message] {
        let selectSQL = """
        SELECT id, payload FROM messages
        ORDER BY created_at ASC
        LIMIT ?;
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare select statement")
        }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var out: [Message] = []
        var quarantined: [(id: String, payload: Data, reason: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let idCString = sqlite3_column_text(stmt, 0)
            let id = idCString.map { String(cString: $0) } ?? "<unknown>"

            let length = sqlite3_column_bytes(stmt, 1)
            guard length > 0, let bytes = sqlite3_column_blob(stmt, 1) else {
                quarantined.append((id: id, payload: Data(), reason: "empty payload"))
                continue
            }
            let data = Data(bytes: bytes, count: Int(length))
            do {
                let msg = try decoder.decode(Message.self, from: data)
                out.append(msg)
            } catch {
                // Undecodable payload. Likely from an older or future
                // SDK build with an incompatible JSON shape, or a row
                // tampered with on disk. Move it out of the active queue
                // so we don't keep tripping on it; surface to logs +
                // diagnostics via `quarantineCount`.
                quarantined.append((id: id, payload: data, reason: "decode failed: \(error)"))
            }
        }

        // Move undecodable rows to quarantine + remove from main table.
        // Done outside the SELECT loop so we don't invalidate `stmt`.
        if !quarantined.isEmpty {
            for row in quarantined {
                try StorageMigrator.quarantine(
                    db,
                    originalId: row.id,
                    payload: row.payload,
                    reason: row.reason,
                    logger: logger
                )
            }
            try await deleteMessages(quarantined.map(\.id))
        }
        return out
    }

    func quarantineCount() async throws -> Int {
        try StorageMigrator.quarantineCount(db)
    }

    func deleteMessages(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let deleteSQL = "DELETE FROM messages WHERE id IN (\(placeholders));"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare delete statement")
        }
        for (i, id) in ids.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MessageStorageError.storageError("Failed to delete messages")
        }
    }

    func getQueueSize() async throws -> Int {
        let countSQL = "SELECT COUNT(*) FROM messages;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare count statement")
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    func clearQueue() async throws {
        if sqlite3_exec(db, "DELETE FROM messages;", nil, nil, nil) != SQLITE_OK {
            throw MessageStorageError.storageError("Failed to clear queue")
        }
    }

    @discardableResult
    func dropOldest(_ count: Int) async throws -> Int {
        guard count > 0 else { return 0 }
        // Delete the `count` rows with the smallest created_at. SQLite
        // supports DELETE-with-LIMIT-via-subquery; this works on all
        // versions we ship against.
        let sql = """
        DELETE FROM messages
        WHERE id IN (
            SELECT id FROM messages
            ORDER BY created_at ASC
            LIMIT ?
        );
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare dropOldest statement")
        }
        sqlite3_bind_int(stmt, 1, Int32(count))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MessageStorageError.storageError("Failed to execute dropOldest")
        }
        return Int(sqlite3_changes(db))
    }
}
