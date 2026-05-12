//
//  StorageMigrationTests.swift
//  GalvaTests
//
//  Locks in the SDK's upgrade safety contract:
//
//    1. Fresh install bootstraps the current schema and stamps
//       user_version.
//    2. Existing v1 DBs reopen without re-migrating.
//    3. A DB from a *future* SDK is refused (downgrade safety) without
//       touching the on-disk data.
//    4. Un-decodable rows land in quarantine, not silent /dev/null.
//    5. The quarantine table is bounded.
//
//  Each test uses a fresh temp .db so they're parallel-safe and never
//  touch shared user state.
//

import Foundation
import SQLite3
@testable import Galva
import XCTest

final class StorageMigrationTests: XCTestCase {

    // MARK: - Fresh install

    func test_freshInstall_stampsCurrentSchemaVersion() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        // Just opening the DB should run case 1 and set user_version.
        let version = readUserVersion(at: handle.path)
        XCTAssertEqual(version, StorageMigrator.currentVersion,
                       "Fresh DB should be stamped at the SDK's current schema version")
    }

    func test_freshInstall_createsBothMessagesAndQuarantineTables() throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        XCTAssertTrue(tableExists("messages", at: handle.path))
        XCTAssertTrue(tableExists("messages_quarantine", at: handle.path))
    }

    // MARK: - Idempotency

    func test_reopen_doesNotReRunMigrations() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        // Write something so we can detect an inadvertent wipe.
        try await handle.storage.storeMessage(.makeTrack(event: "survivor"))
        let originalCount = try await handle.storage.getQueueSize()
        XCTAssertEqual(originalCount, 1)

        // Close + reopen the same DB.
        let reopened = try SQLiteMessageStorage(dbPath: handle.path)
        let reopenedCount = try await reopened.getQueueSize()
        XCTAssertEqual(reopenedCount, 1, "Reopen must not wipe data")
        XCTAssertEqual(readUserVersion(at: handle.path),
                       StorageMigrator.currentVersion,
                       "Reopen must not change user_version")
    }

    // MARK: - Legacy bootstrap (user_version = 0)

    func test_existingDBWithoutUserVersion_migratesCleanly() async throws {
        // Simulate the on-disk state of a user upgrading from a pre-
        // versioning SDK build. Open with raw sqlite3, create the
        // legacy `messages` table without setting user_version, write
        // a row, close. Then let the SDK open it — case 1 should run
        // and the row should be preserved.
        let path = NSTemporaryDirectory()
            .appending("galva-legacy-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeLegacyDB(at: path, withMessages: 3)

        // Sanity check: legacy DB has user_version=0 and no quarantine table.
        XCTAssertEqual(readUserVersion(at: path), 0)
        XCTAssertFalse(tableExists("messages_quarantine", at: path))

        // Open with the SDK — should migrate.
        let storage = try SQLiteMessageStorage(dbPath: path)
        XCTAssertEqual(readUserVersion(at: path), StorageMigrator.currentVersion)
        XCTAssertTrue(tableExists("messages_quarantine", at: path))

        // Critically: existing rows must still be there.
        let preserved = try await storage.getQueueSize()
        XCTAssertEqual(preserved, 3,
                       "Pending messages from the previous SDK build must survive")
    }

    // MARK: - Downgrade safety

    func test_futureSchemaVersion_refusesToOpen() throws {
        // Future version: user_version = 999. Older SDK opens, sees the
        // higher version, throws — the caller falls back to in-memory.
        let path = NSTemporaryDirectory()
            .appending("galva-future-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeRawDB(at: path, statements: [
            "CREATE TABLE messages (id TEXT, payload BLOB, created_at REAL);",
            "PRAGMA user_version = 999;",
        ])

        XCTAssertThrowsError(try SQLiteMessageStorage(dbPath: path)) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("999") || message.contains("newer"),
                          "Error should mention the version mismatch; got: \(message)")
        }
    }

    func test_futureSchemaRefusal_doesNotMutateDisk() throws {
        // Refusing to open a future-version DB must leave it untouched.
        // We snapshot user_version before and after.
        let path = NSTemporaryDirectory()
            .appending("galva-future-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(atPath: path) }

        try writeRawDB(at: path, statements: [
            "CREATE TABLE messages (id TEXT, payload BLOB, created_at REAL);",
            "INSERT INTO messages (id, payload) VALUES ('precious', x'deadbeef');",
            "PRAGMA user_version = 999;",
        ])
        let beforeVersion = readUserVersion(at: path)
        let beforeCount = rawRowCount(table: "messages", at: path)

        XCTAssertThrowsError(try SQLiteMessageStorage(dbPath: path))

        XCTAssertEqual(readUserVersion(at: path), beforeVersion,
                       "Refused open must not touch user_version")
        XCTAssertEqual(rawRowCount(table: "messages", at: path), beforeCount,
                       "Refused open must not touch row data")
    }

    // MARK: - Quarantine

    func test_undecodablePayload_movesToQuarantineAndIsRemovedFromMain() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        // Write one good message + one bad row via raw SQL.
        try await handle.storage.storeMessage(.makeTrack(event: "good"))
        try insertRawRow(at: handle.path, id: "bad-id", payload: Data("not json".utf8))
        let countBefore = try await handle.storage.getQueueSize()
        XCTAssertEqual(countBefore, 2)

        // fetchMessages should drop the bad row into quarantine.
        let fetched = try await handle.storage.fetchMessages(limit: 100)
        XCTAssertEqual(fetched.map(\.event), ["good"])

        let mainCount = try await handle.storage.getQueueSize()
        XCTAssertEqual(mainCount, 1, "Bad row should be removed from main table")
        let quarantined = try await handle.storage.quarantineCount()
        XCTAssertEqual(quarantined, 1, "Bad row should land in quarantine")
    }

    func test_quarantineCount_isCappedAtMaxRows() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        let overflow = Int(StorageMigrator.maxQuarantineRows) + 25
        // Insert overflow bad rows. Each fetch loop puts them in quarantine.
        for i in 0..<overflow {
            try insertRawRow(at: handle.path, id: "bad-\(i)", payload: Data("nope".utf8))
        }
        // One fetch call processes them all (they're all bad → all go to quarantine).
        _ = try await handle.storage.fetchMessages(limit: overflow + 10)

        let quarantined = try await handle.storage.quarantineCount()
        XCTAssertEqual(quarantined, Int(StorageMigrator.maxQuarantineRows),
                       "Quarantine table must be bounded — got \(quarantined)")
    }

    func test_inMemoryStorage_reportsZeroQuarantine() async throws {
        let storage = InMemoryMessageStorage()
        let count = try await storage.quarantineCount()
        XCTAssertEqual(count, 0, "InMemory storage has no quarantine")
    }

    // MARK: - Raw-SQLite helpers
    //
    // We use the same SQLite3 module the SDK uses to set up test
    // fixtures (legacy DB shapes, manually-corrupt rows, future
    // user_version). Keeps test code expressive and avoids reaching
    // into private SDK internals.

    private func readUserVersion(at path: String) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int(stmt, 0)
        }
        return -1
    }

    private func tableExists(_ name: String, at path: String) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return false }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func rawRowCount(table: String, at path: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // Table name can't be a bound parameter; it's controlled by the
        // test so interpolation is safe.
        let sql = "SELECT COUNT(*) FROM \(table);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return -1
    }

    /// Create a DB matching the shape produced by the pre-versioning SDK
    /// builds (no user_version, no quarantine table, just `messages`).
    private func writeLegacyDB(at path: String, withMessages count: Int) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw TestError("sqlite_open")
        }
        defer { sqlite3_close(db) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        try exec(db, """
            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL DEFAULT (julianday('now'))
            );
        """)
        try exec(db, "CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);")

        // Encode `count` valid Message rows using the same JSON shape
        // the production SDK writes (so reopen-and-fetch can decode them).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        for i in 0..<count {
            let msg = Message.makeTrack(event: "legacy-\(i)")
            let data = try encoder.encode(msg)
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT INTO messages (id, payload) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK else {
                throw TestError("prepare legacy insert")
            }
            sqlite3_bind_text(stmt, 1, msg.id, -1, SQLITE_TRANSIENT)
            _ = data.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw TestError("step legacy insert")
            }
        }
    }

    private func writeRawDB(at path: String, statements: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw TestError("open") }
        defer { sqlite3_close(db) }
        for sql in statements {
            try exec(db, sql)
        }
    }

    private func insertRawRow(at path: String, id: String, payload: Data) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw TestError("open") }
        defer { sqlite3_close(db) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "INSERT INTO messages (id, payload) VALUES (?, ?);", -1, &stmt, nil) == SQLITE_OK else {
            throw TestError("prepare raw insert")
        }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        _ = payload.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw TestError("step raw insert")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TestError("exec failed: \(msg)")
        }
    }
}
