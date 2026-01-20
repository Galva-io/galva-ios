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
