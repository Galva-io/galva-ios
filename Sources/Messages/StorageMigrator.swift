//
//  StorageMigrator.swift
//  Galva
//
//  SQLite schema migrations + quarantine for un-decodable rows + the
//  runbook for future SDK upgrades.
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Why this exists
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  When a host app updates the Galva SDK, anywhere from zero to ten
//  thousand pending messages can be on disk from the previous version,
//  plus a table layout the new SDK might or might not know how to read.
//
//  An SDK that crashes the host app on first launch after upgrade, or
//  silently drops queued events, is worse than no SDK at all — the user
//  blames the host app and there's no breadcrumb to trace it back.
//
//  Migration is therefore part of the SDK's safety contract.
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Versioning model
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Two distinct versions, tracked separately:
//
//    SCHEMA VERSION   `PRAGMA user_version` on the SQLite database.
//                     Bumped when the *table structure* changes (new
//                     columns, indexes, tables). Owned by this file.
//
//    PAYLOAD VERSION  Implicit in the Message Codable. Bumped when the
//                     *JSON shape* inside the `payload` column changes.
//                     Forward compat comes from additive-Codable rules
//                     below — no explicit version field needed yet.
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Upgrade runbook — what you do when shipping each kind of change
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
//  • Adding a column / table / index (most common):
//       1. Bump `currentVersion` by 1 below.
//       2. Add a `case N:` arm to `runMigration(to:db:logger:)` with the
//          SQL (`ALTER TABLE messages ADD COLUMN ...` is idempotent under
//          our flow only if you check first; prefer adding a new table).
//       3. Add a fixture-based test in StorageMigrationTests that opens
//          a v(N-1) DB and confirms the migration runs and is
//          idempotent (running migrate() twice is a no-op the 2nd time).
//
//  • Adding an OPTIONAL JSON field to Message:
//       — Just add the field as `Optional<T>`. Old payloads decode
//         (Codable treats absent keys as nil). No version bump.
//
//  • Adding a REQUIRED JSON field:
//       — Don't, if you can avoid it. If you must, write a payload
//         migration that synthesises the field for existing rows.
//
//  • Renaming or removing a JSON field:
//       — Don't, unless you can keep the OLD name as a Codable alias for
//         one major version. Then drop it the version after that.
//
//  • Renaming a discriminator value (e.g. "track" → "event"):
//       — Make Codable accept both for one major version; emit only the
//         new value. Drop the old name the version after.
//
//  • Downgrade safety (user reinstalls older SDK):
//       — `migrate(_:)` refuses to open a DB whose `user_version` is
//         higher than `currentVersion`, throws, and the queue falls back
//         to in-memory storage. The on-disk data is NEVER wiped — the
//         next forward upgrade picks up where it left off.
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Quarantine
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  When a row fails to decode (corrupt JSON, payload from a future SDK
//  build we don't know how to read, hand-edited tampering), it's moved
//  to `messages_quarantine` instead of silently skipped. The table is
//  capped at `maxQuarantineRows` with FIFO eviction so it stays bounded.
//  Support can ask the developer to dump the table — three columns are
//  enough to diagnose almost anything: `original_id`, `payload`,
//  `reason`. Logged at `.warning` every time a row gets quarantined.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_MIGRATOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StorageMigrator {

    /// The schema version this build of the SDK writes. Bump in lockstep
    /// with a new `case N:` arm in `runMigration(to:db:logger:)`.
    static let currentVersion: Int32 = 1

    /// Quarantine table is bounded: oldest rows drop once we exceed this.
    /// 100 is plenty for forensics — enough to spot a pattern, not so
    /// many that the user's disk fills up with garbage.
    static let maxQuarantineRows: Int32 = 100

    // MARK: - Public API

    /// Run forward-only migrations from whatever schema is on disk to
    /// `currentVersion`. Throws on downgrade scenarios — caller is
    /// expected to fall back to in-memory storage so the on-disk data
    /// stays untouched for the next forward upgrade.
    static func migrate(_ db: OpaquePointer?, logger: any GalvaLogger) throws {
        let onDisk = readUserVersion(db)

        guard onDisk <= currentVersion else {
            throw MessageStorageError.storageError(
                "SQLite schema version \(onDisk) is newer than this SDK can read (max: \(currentVersion)). " +
                "Refusing to open — pending messages preserved on disk."
            )
        }

        guard onDisk < currentVersion else {
            logger.debug(.storage, "schema already at current version",
                         metadata: ["version": String(onDisk)])
            return
        }

        // 0 (fresh DB or pre-versioning) → 1, 1 → 2, etc.
        for target in (onDisk + 1)...currentVersion {
            logger.info(.storage, "running schema migration",
                        metadata: ["from": String(target - 1), "to": String(target)])
            try runMigration(to: target, db: db, logger: logger)
            try setUserVersion(db, to: target)
        }
    }

    /// Move an un-decodable row to the quarantine table and log a
    /// warning. Used by the fetch path when a payload can't be parsed.
    static func quarantine(
        _ db: OpaquePointer?,
        originalId: String?,
        payload: Data,
        reason: String,
        logger: any GalvaLogger
    ) throws {
        let insertSQL = """
            INSERT INTO messages_quarantine (original_id, payload, reason)
            VALUES (?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("failed to prepare quarantine insert")
        }
        if let id = originalId {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_MIGRATOR)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        _ = payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(payload.count), SQLITE_TRANSIENT_MIGRATOR)
        }
        sqlite3_bind_text(stmt, 3, reason, -1, SQLITE_TRANSIENT_MIGRATOR)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw MessageStorageError.storageError("failed to insert quarantine row")
        }
        try evictQuarantineOverCap(db)

        logger.warning(.storage, "quarantined undecodable message", metadata: [
            "id": originalId ?? "<unknown>",
            "reason": reason,
            "payloadBytes": String(payload.count),
        ])
    }

    /// How many rows currently sit in quarantine. Surfaced via the
    /// storage protocol for tests and ad-hoc diagnostics.
    static func quarantineCount(_ db: OpaquePointer?) throws -> Int {
        let sql = "SELECT COUNT(*) FROM messages_quarantine;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("failed to prepare quarantineCount")
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Migration arms

    private static func runMigration(to target: Int32, db: OpaquePointer?, logger: any GalvaLogger) throws {
        switch target {
        case 1:
            // Initial schema. Uses IF NOT EXISTS so existing v0 DBs
            // (created before we tracked user_version) migrate cleanly
            // to v1 without losing their queued rows.
            try exec(db, """
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY,
                    payload BLOB NOT NULL,
                    created_at REAL NOT NULL DEFAULT (julianday('now'))
                );
            """)
            try exec(db, """
                CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);
            """)
            try exec(db, """
                CREATE TABLE IF NOT EXISTS messages_quarantine (
                    rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                    original_id TEXT,
                    payload BLOB NOT NULL,
                    quarantined_at REAL NOT NULL DEFAULT (julianday('now')),
                    reason TEXT
                );
            """)

        // === Future migrations land here ===
        //
        // case 2:
        //   try exec(db, "ALTER TABLE messages ADD COLUMN schema_version INTEGER NOT NULL DEFAULT 1;")
        //   // Then add a v1-fixture test in StorageMigrationTests.

        default:
            throw MessageStorageError.storageError(
                "no migration registered for target version \(target) — bump currentVersion in lockstep with a new case arm"
            )
        }
    }

    // MARK: - Internals

    private static func evictQuarantineOverCap(_ db: OpaquePointer?) throws {
        try exec(db, """
            DELETE FROM messages_quarantine
            WHERE rowid IN (
                SELECT rowid FROM messages_quarantine
                ORDER BY quarantined_at ASC
                LIMIT MAX(0, (SELECT COUNT(*) FROM messages_quarantine) - \(maxQuarantineRows))
            );
        """)
    }

    private static func readUserVersion(_ db: OpaquePointer?) -> Int32 {
        let sql = "PRAGMA user_version;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return 0
    }

    private static func setUserVersion(_ db: OpaquePointer?, to v: Int32) throws {
        // PRAGMA user_version doesn't accept bound parameters — value is
        // an integer this code controls, so interpolation is safe here.
        try exec(db, "PRAGMA user_version = \(v);")
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MessageStorageError.storageError("SQL exec failed: \(msg) (sql: \(sql.prefix(120)))")
        }
    }
}
