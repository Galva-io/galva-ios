//
//  InAppMessageDelivery.swift
//  Galva
//
//  Puts each in-app message the SDK publishes in front of the user, the way
//  `Galva.configure(…, inAppMessages:)` asked:
//
//    • `.automatic` (default) — the SDK presents it on the app's active
//      window scene, through the same presenter Galva's deep links use.
//    • `.manual(handler:)` — the SDK hands it to the app's handler, which
//      decides when and where it appears.
//
//  It subscribes to `InAppMessageStream` once, at configure, BEFORE the
//  lifecycle observer's first foreground poll can publish anything — the
//  stream only delivers to subscribers that already exist, so a message
//  published with nobody listening wouldn't show until the next cold start.
//
//  Messages are delivered one at a time, in order: the next waits until the
//  current presentation (or handler) returns. Pacing — at most one message
//  per foreground stint — is enforced upstream by `InAppMessageManager`.
//

import Foundation

@MainActor
final class InAppMessageDelivery {

    /// Puts one message on screen.
    typealias Deliver = @MainActor @Sendable (InAppMessages.Message) async -> Void

    private var task: Task<Void, Never>?

    nonisolated init() {}

    /// Start delivering `messages`. `presentAutomatically` is how the SDK
    /// presents a message itself, used in `.automatic` mode. Idempotent.
    func start(
        _ presentation: InAppMessages.Presentation,
        messages: AsyncStream<InAppMessages.Message>,
        presentAutomatically: @escaping Deliver
    ) {
        guard task == nil else { return }
        let deliver: Deliver
        switch presentation {
        case .automatic:
            deliver = presentAutomatically
        case .manual(let handler):
            deliver = handler
        }
        task = Task { @MainActor in
            for await message in messages {
                await deliver(message)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
