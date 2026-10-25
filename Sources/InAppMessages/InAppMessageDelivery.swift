//
//  InAppMessageDelivery.swift
//  Galva
//
//  `.automatic` presentation: presents each in-app message the SDK
//  publishes, on the app's active window scene, through the same presenter
//  Galva's deep links use. In `.manual` mode it isn't started — the app
//  reads `InAppMessages.messages` and presents messages itself.
//
//  It subscribes to `InAppMessageStream` once, at configure, BEFORE the
//  lifecycle observer's first foreground poll can publish anything.
//  Messages are presented one at a time, in order: the next waits until the
//  current presentation returns. Pacing — at most one message per
//  foreground stint — is enforced upstream by `InAppMessageManager`.
//

import Foundation

@MainActor
final class InAppMessageDelivery {

    /// Presents one message.
    typealias Present = @MainActor @Sendable (InAppMessages.Message) async -> Void

    private var task: Task<Void, Never>?

    nonisolated init() {}

    /// Start presenting `messages` with `present`. Idempotent.
    func start(messages: AsyncStream<InAppMessages.Message>, present: @escaping Present) {
        guard task == nil else { return }
        task = Task { @MainActor in
            for await message in messages {
                await present(message)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
