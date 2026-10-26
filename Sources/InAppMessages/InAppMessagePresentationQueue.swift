//
//  InAppMessagePresentationQueue.swift
//  Galva
//
//  Runs in-app message presentations one at a time, in call order, for
//  `InAppMessagePresenter.show`. Each show suspends (resolve, bundle
//  download, UIKit's present), so without this two calls — the same `gv`
//  link opened twice, a deep link landing while an automatic presentation
//  resolves — would both present, and only the last sheet would be
//  tracked (the other could never be dismissed).
//
//  A call for a message already queued or running is dropped. Waiting is
//  bounded by the presentation ahead, which the presenter bounds itself.
//

import Foundation

@MainActor
final class InAppMessagePresentationQueue {

    /// Message ids queued or running, oldest first. The first one runs.
    private var ids: [String] = []

    /// One per queued call after the running one, in the same order.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated init() {}

    /// Whether a call for `id` is queued or running.
    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    /// Run `operation` once every earlier call has finished. Returns `false`
    /// without running it when a call for `id` is already queued or running.
    @discardableResult
    func run(id: String, _ operation: () async throws -> Void) async rethrows -> Bool {
        guard !ids.contains(id) else { return false }
        ids.append(id)
        if ids.count > 1 {
            await withCheckedContinuation { waiters.append($0) }
        }
        defer {
            ids.removeFirst()
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
        try await operation()
        return true
    }
}
