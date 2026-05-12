//
//  MessageStorageContractTests.swift
//  GalvaTests
//
//  A single contract that both MessageStorage implementations must satisfy.
//  Subclasses provide a factory; the base class runs the test methods.
//
//  Why this shape: if we add a new storage backend (Core Data, Realm, a
//  remote queue), we just subclass and supply a factory. The behavioural
//  guarantees stay in one place and can't drift between backends.
//

import Foundation
import SQLite3
@testable import Galva
import XCTest

// MARK: - Shared contract

class MessageStorageContractTests: XCTestCase {

    /// Subclass override — returns a fresh, isolated storage instance.
    /// Default returns `nil` so the base test class is silently skipped
    /// when XCTest runs it directly.
    func makeStorage() async throws -> (any MessageStorage)? { nil }

    /// Override for any per-test cleanup (e.g. delete the .db file).
    func cleanupStorage(_: any MessageStorage) async {}

    // MARK: Round-trip

    func test_contract_storeAndFetchSingle() async throws {
        guard let storage = try await makeStorage() else { return }

        let msg = Message.makeTrack(event: "single")
        try await storage.storeMessage(msg)

        let fetched = try await storage.fetchMessages(limit: 10)
        XCTAssertEqual(fetched.map(\.event), ["single"])
        let size = try await storage.getQueueSize()
        XCTAssertEqual(size, 1)
    }

    func test_contract_fetchPreservesFIFOOrder() async throws {
        guard let storage = try await makeStorage() else { return }

        for msg in Message.sequence(prefix: "ord", count: 5) {
            try await storage.storeMessage(msg)
        }

        let fetched = try await storage.fetchMessages(limit: 10)
        XCTAssertEqual(
            fetched.map(\.event),
            (0 ..< 5).map { "ord-\(String(format: "%03d", $0))" }
        )
    }

    func test_contract_fetchRespectsLimit() async throws {
        guard let storage = try await makeStorage() else { return }

        for msg in Message.sequence(prefix: "lim", count: 10) {
            try await storage.storeMessage(msg)
        }
        let firstTwo = try await storage.fetchMessages(limit: 2)
        XCTAssertEqual(firstTwo.map(\.event), ["lim-000", "lim-001"])

        // fetch is non-destructive — fetching again yields the same prefix.
        let firstTwoAgain = try await storage.fetchMessages(limit: 2)
        XCTAssertEqual(firstTwoAgain.map(\.event), ["lim-000", "lim-001"])
    }

    // MARK: Delete

    func test_contract_deleteRemovesOnlyMatchingIds() async throws {
        guard let storage = try await makeStorage() else { return }

        let msgs = Message.sequence(prefix: "del", count: 5)
        for m in msgs { try await storage.storeMessage(m) }

        // Delete the middle three.
        let toDelete = msgs[1 ... 3].map(\.id)
        try await storage.deleteMessages(toDelete)

        let remaining = try await storage.fetchMessages(limit: 10)
        XCTAssertEqual(remaining.map(\.event), ["del-000", "del-004"])
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 2)
    }

    func test_contract_deleteNonExistentIsNoOp() async throws {
        guard let storage = try await makeStorage() else { return }

        for m in Message.sequence(prefix: "noop", count: 2) {
            try await storage.storeMessage(m)
        }
        try await storage.deleteMessages(["does-not-exist", "neither-does-this"])

        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 2)
    }

    func test_contract_deleteEmptyIsNoOp() async throws {
        guard let storage = try await makeStorage() else { return }

        try await storage.storeMessage(.makeTrack(event: "alone"))
        try await storage.deleteMessages([])

        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 1)
    }

    // MARK: Clear

    func test_contract_clearEmptiesStorage() async throws {
        guard let storage = try await makeStorage() else { return }

        for m in Message.sequence(prefix: "wipe", count: 4) {
            try await storage.storeMessage(m)
        }
        try await storage.clearQueue()

        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0)
        let fetched = try await storage.fetchMessages(limit: 10)
        XCTAssertTrue(fetched.isEmpty)
    }

    func test_contract_emptyStorageOperationsAreSafe() async throws {
        guard let storage = try await makeStorage() else { return }

        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0)
        await XCTAsyncAssertTrue(try await storage.fetchMessages(limit: 5).isEmpty)
        try await storage.clearQueue()
        try await storage.deleteMessages(["unknown"])
        await XCTAsyncAssertEqual(try await storage.getQueueSize(), 0)
    }

    // MARK: Round-trip fidelity (track + identify bodies + properties)

    func test_contract_messageRoundTripsLosslessly() async throws {
        guard let storage = try await makeStorage() else { return }

        let traits: [String: AnyJSONValue] = [
            "email": .string("a@b.co"),
            "count": .int(42),
            "ratio": .double(1.5),
            "active": .bool(true),
        ]
        let original = Message.makeIdentify(
            userId: "user-7",
            anonymousId: "anon-7",
            traits: traits
        )
        try await storage.storeMessage(original)

        let fetched = try await storage.fetchMessages(limit: 1)
        XCTAssertEqual(fetched.count, 1)
        let round = fetched[0]
        XCTAssertEqual(round.endUserId, "user-7")
        XCTAssertEqual(round.anonymousId, "anon-7")
        XCTAssertEqual(round.traits?["email"], .string("a@b.co"))
        XCTAssertEqual(round.traits?["count"], .int(42))
        XCTAssertEqual(round.traits?["ratio"], .double(1.5))
        XCTAssertEqual(round.traits?["active"], .bool(true))
    }
}

// MARK: - InMemory specialisation

final class InMemoryStorageContractTests: MessageStorageContractTests {
    override func makeStorage() async throws -> (any MessageStorage)? {
        TestStorage.memory()
    }
}

// MARK: - SQLite specialisation

final class SQLiteStorageContractTests: MessageStorageContractTests {
    private var handles: [TempSQLiteHandle] = []

    override func makeStorage() async throws -> (any MessageStorage)? {
        let handle = try TestStorage.sqlite()
        handles.append(handle)
        return handle.storage
    }

    override func tearDown() async throws {
        for handle in handles { handle.cleanup() }
        handles.removeAll()
        try await super.tearDown()
    }
}

// MARK: - SQLite-only: persistence across instances

final class SQLitePersistenceTests: XCTestCase {

    func test_messagesPersistAcrossSeparateStorageInstances() async throws {
        let handle = try TestStorage.sqlite()
        defer { handle.cleanup() }

        try await handle.storage.storeMessage(.makeTrack(event: "first-life"))
        await XCTAsyncAssertEqual(try await handle.storage.getQueueSize(), 1)

        // Drop the reference, reopen.
        let second = try SQLiteMessageStorage(dbPath: handle.path)
        await XCTAsyncAssertEqual(try await second.getQueueSize(), 1)
        let fetched = try await second.fetchMessages(limit: 1)
        XCTAssertEqual(fetched.map(\.event), ["first-life"])
    }

    func test_corruptRowIsSkippedNotFatal() async throws {
        // We can't easily inject a corrupt row without touching SQLite
        // directly. Instead we verify that fetching is tolerant — empty
        // payload column counts as corrupt and is skipped.
        let path = NSTemporaryDirectory().appending("galva-corrupt-\(UUID().uuidString).db")
        let storage = try SQLiteMessageStorage(dbPath: path)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await storage.storeMessage(.makeTrack(event: "valid"))
        // Insert a row with empty payload using raw SQLite via a second handle.
        try insertCorruptRow(path: path)

        let fetched = try await storage.fetchMessages(limit: 10)
        XCTAssertEqual(fetched.count, 1,
                       "Corrupt row must be skipped, valid row preserved")
        XCTAssertEqual(fetched[0].event, "valid")
    }

    private func insertCorruptRow(path: String) throws {
        // Tiny helper to drop a bad row using a fresh sqlite3 handle.
        // Imported via the same SQLite3 module the SDK uses.
        let raw = path.cString(using: .utf8)!
        var db: OpaquePointer?
        guard sqlite3_open(raw, &db) == SQLITE_OK else {
            throw TestError("sqlite_open failed")
        }
        defer { sqlite3_close(db) }
        let sql = "INSERT INTO messages (id, payload) VALUES ('bad-id', x'');"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError("insert corrupt failed")
        }
    }
}
