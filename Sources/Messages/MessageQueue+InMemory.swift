//
//  MessageQueue+InMemory.swift
//  Galva
//
//  Created by Claude Code on 11/9/25.
//

import Foundation

actor InMemoryMessageStorage: MessageStorage {
    private var messages: [StoredMessage] = []

    private struct StoredMessage {
        let message: Message
        let createdAt: Date

        init(_ message: Message) {
            self.message = message
            createdAt = Date()
        }
    }

    func storeMessage(_ message: Message) async throws {
        let storedMessage = StoredMessage(message)
        messages.append(storedMessage)
    }

    func fetchMessages(limit: Int) async throws -> [Message] {
        // Sort by creation order (FIFO)
        let sortedMessages = messages.sorted { $0.createdAt < $1.createdAt }
        let limitedMessages = Array(sortedMessages.prefix(limit))
        return limitedMessages.map { $0.message }
    }

    func deleteMessages(_ ids: [String]) async throws {
        let idsSet = Set(ids)
        messages.removeAll { storedMessage in
            idsSet.contains(storedMessage.message.id)
        }
    }

    func getQueueSize() async throws -> Int {
        return messages.count
    }

    func clearQueue() async throws {
        messages.removeAll()
    }

    @discardableResult
    func dropOldest(_ count: Int) async throws -> Int {
        guard count > 0, !messages.isEmpty else { return 0 }
        // Sorted by insertion order in this in-memory implementation.
        let sorted = messages.sorted { $0.createdAt < $1.createdAt }
        let drop = min(count, sorted.count)
        let droppedIds = Set(sorted.prefix(drop).map { $0.message.id })
        messages.removeAll { droppedIds.contains($0.message.id) }
        return drop
    }
}
