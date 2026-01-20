//
//  MessageQueue+SQLite.swift
//  Galva
//
//  Created by Claude Code on 11/9/25.
//

import Foundation
import SQLite3

actor SQLiteMessageStorage: MessageStorage {
    private var db: OpaquePointer?
    private let dbPath: String

    init(dbPath: String) throws {
        self.dbPath = dbPath

        // Initialize database synchronously during actor creation
        var tempDb: OpaquePointer?
        if sqlite3_open(dbPath, &tempDb) != SQLITE_OK {
            throw MessageStorageError.storageError("Unable to open database at path: \(dbPath)")
        }
        db = tempDb

        // Create table synchronously
        let createTableSQL = """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            user_id TEXT,
            anonymous_id TEXT,
            timestamp REAL NOT NULL,
            api_version TEXT NOT NULL,
            event TEXT,
            properties TEXT,
            context TEXT NOT NULL,
            created_at REAL NOT NULL DEFAULT (julianday('now'))
        );
        """

        if sqlite3_exec(tempDb, createTableSQL, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(tempDb)
            throw MessageStorageError.storageError("Unable to create messages table")
        }

        let createIndexSQL = "CREATE INDEX IF NOT EXISTS idx_messages_created_at ON messages(created_at);"
        if sqlite3_exec(tempDb, createIndexSQL, nil, nil, nil) != SQLITE_OK {
            sqlite3_close(tempDb)
            throw MessageStorageError.storageError("Unable to create index")
        }
    }

    func storeMessage(_ message: Message) async throws {
        let insertSQL = """
        INSERT INTO messages (id, type, user_id, anonymous_id, timestamp, api_version, event, properties, context)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) != SQLITE_OK {
            throw MessageStorageError.storageError("Failed to prepare insert statement")
        }

        sqlite3_bind_text(statement, 1, message.id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, message.type.rawValue, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if let userId = message.userId {
            sqlite3_bind_text(statement, 3, userId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, 3)
        }

        if let anonymousId = message.anonymousId {
            sqlite3_bind_text(statement, 4, anonymousId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, 4)
        }

        sqlite3_bind_double(statement, 5, message.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 6, message.apiVersion, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if let event = message.event {
            sqlite3_bind_text(statement, 7, event, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, 7)
        }

        if let properties = message.properties {
            let propertiesData = try JSONEncoder().encode(properties)
            let propertiesString = String(data: propertiesData, encoding: .utf8) ?? ""
            sqlite3_bind_text(statement, 8, propertiesString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(statement, 8)
        }

        let contextData = try JSONEncoder().encode(message.context)
        let contextString = String(data: contextData, encoding: .utf8) ?? ""
        sqlite3_bind_text(statement, 9, contextString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(statement) != SQLITE_DONE {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw MessageStorageError.storageError("Failed to insert message: \(errorMessage)")
        }
    }

    func fetchMessages(limit: Int) async throws -> [Message] {
        let selectSQL = """
        SELECT id, type, user_id, anonymous_id, timestamp, api_version, event, properties, context
        FROM messages 
        ORDER BY created_at ASC 
        LIMIT ?;
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, selectSQL, -1, &statement, nil) != SQLITE_OK {
            throw MessageStorageError.storageError("Failed to prepare select statement")
        }

        sqlite3_bind_int(statement, 1, Int32(limit))

        var messages: [Message] = []
        let decoder = JSONDecoder()

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(statement, 0))
            let typeString = String(cString: sqlite3_column_text(statement, 1))
            let type = Message.MessageType(rawValue: typeString) ?? .track

            let userId =
                sqlite3_column_text(statement, 2) != nil
                    ? String(cString: sqlite3_column_text(statement, 2)) : nil
            let anonymousId =
                sqlite3_column_text(statement, 3) != nil
                    ? String(cString: sqlite3_column_text(statement, 3)) : nil

            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))

            let apiVersion = String(cString: sqlite3_column_text(statement, 5))
            let event =
                sqlite3_column_text(statement, 6) != nil
                    ? String(cString: sqlite3_column_text(statement, 6)) : nil

            var properties: [String: RevFlowPrimitive]?
            if sqlite3_column_type(statement, 7) != SQLITE_NULL {
                if let propertiesText = sqlite3_column_text(statement, 7) {
                    let propertiesString = String(cString: propertiesText)
                    if let data = propertiesString.data(using: .utf8) {
                        do {
                            properties = try JSONDecoder().decode(
                                [String: RevFlowPrimitive].self, from: data
                            )
                        } catch {
                            print("Failed to decode properties: \(error)")
                            print("Properties JSON string: \(propertiesString)")
                        }
                    }
                }
            }

            let contextString = String(cString: sqlite3_column_text(statement, 8))
            guard let contextData = contextString.data(using: .utf8),
                  let context = try? decoder.decode(Message.Context.self, from: contextData)
            else {
                continue
            }

            let message = Message(
                id: id,
                type: type,
                userId: userId,
                anonymousId: anonymousId,
                timestamp: timestamp,
                apiVersion: apiVersion,
                event: event,
                properties: properties,
                traits: nil,
                context: context
            )

            messages.append(message)
        }

        return messages
    }

    func deleteMessages(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }

        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let deleteSQL = "DELETE FROM messages WHERE id IN (\(placeholders));"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        if sqlite3_prepare_v2(db, deleteSQL, -1, &statement, nil) != SQLITE_OK {
            throw MessageStorageError.storageError("Failed to prepare delete statement")
        }

        for (index, id) in ids.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }

        if sqlite3_step(statement) != SQLITE_DONE {
            throw MessageStorageError.storageError("Failed to delete messages")
        }
    }

    func getQueueSize() async throws -> Int {
        let countSQL = "SELECT COUNT(*) FROM messages;"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, countSQL, -1, &statement, nil) == SQLITE_OK else {
            throw MessageStorageError.storageError("Failed to prepare count statement")
        }

        if sqlite3_step(statement) == SQLITE_ROW {
            return Int(sqlite3_column_int(statement, 0))
        }

        return 0
    }

    func clearQueue() async throws {
        let deleteSQL = "DELETE FROM messages;"

        if sqlite3_exec(db, deleteSQL, nil, nil, nil) != SQLITE_OK {
            throw MessageStorageError.storageError("Failed to clear queue")
        }
    }
}
