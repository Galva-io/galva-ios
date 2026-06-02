//
//  InAppMessageStream.swift
//  Galva
//
//  Multi-consumer broadcast of `InAppMessages.Message` values.
//
//  Why broadcast: a SwiftUI app may have multiple Views that all want to
//  observe new messages (logging, debug overlays, alternate renderers).
//  A single AsyncStream can only be consumed once, so the SDK keeps a
//  registry of continuations and yields each new message to all of them.
//
//  Per-consumer terminations are handled by `onTermination` — when a
//  consumer cancels its iteration, its continuation is removed.
//
//  Isolation: the broadcaster is `@MainActor`. `yield` runs on the main
//  actor, and `InAppMessages.messages` is `@MainActor` too, so the natural
//  `for await` (SwiftUI `.task`, `Task { @MainActor in … }`) delivers each
//  message on the main thread — callers can update UI in the loop body
//  without a manual hop. (AsyncStream resumes on the *consumer's* executor,
//  so this guarantee holds for the standard MainActor-isolated consumption
//  the SDK documents and uses.)
//

import Foundation

@MainActor
final class InAppMessageStream {

    private struct Subscriber: Identifiable {
        let id: UUID
        let continuation: AsyncStream<InAppMessages.Message>.Continuation
    }

    private var subscribers: [Subscriber] = []

    /// Default init runs from non-isolated contexts so SDKCore can hold a
    /// stream instance as a stored property (initialized at construction).
    nonisolated init() {}

    /// Yield `message` to every active subscriber. Subscribers that have
    /// already finished are pruned lazily on the next yield.
    func yield(_ message: InAppMessages.Message) {
        var alive: [Subscriber] = []
        alive.reserveCapacity(subscribers.count)
        for sub in subscribers {
            switch sub.continuation.yield(message) {
            case .enqueued, .dropped:
                alive.append(sub)
            case .terminated:
                continue
            @unknown default:
                alive.append(sub)
            }
        }
        subscribers = alive
    }

    /// Create a fresh consumer stream. Caller can iterate with
    /// `for await message in stream { … }`. Cancelling the iteration
    /// (via `Task.cancel()`) terminates this consumer; other consumers
    /// stay subscribed.
    nonisolated func makeStream() -> AsyncStream<InAppMessages.Message> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { @MainActor in
                self.register(Subscriber(id: id, continuation: continuation))
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.unregister(id: id)
                }
            }
        }
    }

    /// Drop every subscriber. Called when the SDK shuts down or logs out
    /// — pending iterations resolve cleanly with no further yield.
    func terminateAll() {
        for sub in subscribers {
            sub.continuation.finish()
        }
        subscribers.removeAll()
    }

    // MARK: - Subscriber bookkeeping

    private func register(_ subscriber: Subscriber) {
        subscribers.append(subscriber)
    }

    private func unregister(id: UUID) {
        subscribers.removeAll { $0.id == id }
    }
}
