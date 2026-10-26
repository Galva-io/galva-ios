//
//  PresentedMessageLog.swift
//  Galva
//
//  In-app messages that went on screen without Galva's server learning so,
//  kept on the device across launches.
//
//  The server stops returning a message from the poll once it's marked
//  presented, and only the page's `offer_viewed` / `survey_viewed` track
//  events mark it. While the user is opted out the SDK sends neither, and
//  its own dedupe (`InAppMessageManager.seenIds`) lasts only for the process,
//  so without this log the same message would show again on every cold
//  start. The poll skips every id in it, opted out or not.
//
//  Not cleared by logOut or a user switch: it stands in for the server's
//  per-communication `presentedAt`, and a communication id belongs to one
//  identity and is never reused, so it can't hold back another user's
//  messages.
//

import Foundation

@GalvaActor
final class PresentedMessageLog {

    /// `UserDefaults` key holding the ids, oldest first.
    nonisolated static let defaultsKey = "co.galva.presentedMessageIds"

    /// Ids kept. Past it the oldest go first — at most one message shows
    /// per foreground, so this covers far longer than a run stays open.
    nonisolated static let capacity = 200

    private let defaults: UserDefaults
    private var ids: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.ids = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func contains(_ messageId: String) -> Bool {
        ids.contains(messageId.lowercased())
    }

    /// Remember `messageIds` as presented. Writes to `UserDefaults` only
    /// when one is new.
    func record(_ messageIds: [String]) {
        var changed = false
        for id in messageIds.map({ $0.lowercased() }) where !ids.contains(id) {
            ids.append(id)
            changed = true
        }
        guard changed else { return }
        if ids.count > Self.capacity {
            ids.removeFirst(ids.count - Self.capacity)
        }
        defaults.set(ids, forKey: Self.defaultsKey)
    }
}
