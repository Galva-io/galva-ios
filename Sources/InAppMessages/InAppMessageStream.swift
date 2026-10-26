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
//  Held message: a message published while NOBODY is subscribed is kept
//  (newest wins) and handed to the next subscriber, once. In `.manual` mode
//  the app's own loop may start a moment after the first foreground poll
//  publishes — without this, that message wouldn't reach the app until its
//  next cold start. In `.automatic` mode the SDK is always subscribed, so
//  nothing is ever held.
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

    /// Newest message published while nobody was subscribed, waiting for
    /// the next subscriber.
    private(set) var heldMessage: InAppMessages.Message?

    /// Default init runs from non-isolated contexts so SDKCore can hold a
    /// stream instance as a stored property (initialized at construction).
    nonisolated init() {}

    /// Yield `message` to every active subscriber. Subscribers that have
    /// already finished are pruned lazily on the next yield.
    ///
    /// Delivery pacing lives UPSTREAM: `InAppMessageManager` delivers at most
    /// one message per foreground stint and suppresses the fetch entirely
    /// while a deep-link presentation is active (see its display budget), so
    /// by the time a message reaches this broadcast it is cleared to display.
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
        if alive.isEmpty {
            heldMessage = message
        }
    }

    /// Drop the held message — e.g. on logout, since it was addressed to the
    /// previous identity.
    func discardHeldMessage() {
        heldMessage = nil
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
        if let held = heldMessage {
            // A subscriber that went away before its registration ran can't
            // take the held message — keep it for the next one.
            if case .terminated = subscriber.continuation.yield(held) { return }
            heldMessage = nil
        }
        subscribers.append(subscriber)
    }

    private func unregister(id: UUID) {
        subscribers.removeAll { $0.id == id }
    }
}
