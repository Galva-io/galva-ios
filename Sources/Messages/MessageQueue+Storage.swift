//
//  MessageQueue+Storage.swift
//  Galva
//
//  Created by Claude Code on 11/9/25.
//

import Foundation

protocol MessageStorage: Actor {
    /// Store a message in the storage
    func storeMessage(_ message: Message) async throws

    /// Fetch messages from storage with a limit
    func fetchMessages(limit: Int) async throws -> [Message]

    /// Delete messages by their IDs
    func deleteMessages(_ ids: [String]) async throws

    /// Get the current queue size
    func getQueueSize() async throws -> Int

    /// Clear all messages from storage
    func clearQueue() async throws

    /// Delete the N oldest messages. Used by the queue to enforce a hard
    /// cap (`QueueOptions.maxStoredCount`) so an offline device can't grow
    /// the local store unboundedly. Returns the number of rows actually
    /// removed (may be less than `count` if the store has fewer messages).
    @discardableResult
    func dropOldest(_ count: Int) async throws -> Int

    /// Number of rows currently in the quarantine table (un-decodable
    /// messages that couldn't be parsed by the current SDK build). Used
    /// for diagnostics and migration tests. In-memory storage returns 0.
    func quarantineCount() async throws -> Int
}

extension MessageStorage {
    /// Default implementation — only the SQLite backend supports
    /// quarantine. In-memory has nowhere to keep un-decodable rows.
    func quarantineCount() async throws -> Int { 0 }
}

enum MessageStorageError: Error {
    case storageError(String)
    case serializationError(String)

    var localizedDescription: String {
        switch self {
        case let .storageError(message):
            return "Storage error: \(message)"
        case let .serializationError(message):
            return "Serialization error: \(message)"
        }
    }
}
