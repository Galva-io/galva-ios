//
//  IdentityStore.swift
//  Galva
//
//  Owns the two ids attached to every outgoing message:
//
//    • anonymousId — UUID v7, generated on first launch. Always present.
//                    Rotated on logOut() so a re-anonymized user gets a
//                    fresh session id.
//    • endUserId   — your app's user id. nil until identify() is called,
//                    nil again after logOut().
//
//  Persistence: UserDefaults under the standard suite. Tiny payload, fast
//  reads, survives app updates and reinstalls within the same data container.
//

import Foundation

@GalvaActor
final class IdentityStore {
    nonisolated(unsafe) private let defaults: UserDefaults
    private static let anonymousIdKey = "co.galva.anonymousId"
    private static let endUserIdKey   = "co.galva.endUserId"

    private(set) var anonymousId: String
    private(set) var endUserId: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let existing = defaults.string(forKey: Self.anonymousIdKey) {
            anonymousId = existing
        } else {
            let new = UUIDv7.next().uuidString
            defaults.set(new, forKey: Self.anonymousIdKey)
            anonymousId = new
        }

        endUserId = defaults.string(forKey: Self.endUserIdKey)
    }

    func setEndUserId(_ id: String?) {
        endUserId = id
        if let id {
            defaults.set(id, forKey: Self.endUserIdKey)
        } else {
            defaults.removeObject(forKey: Self.endUserIdKey)
        }
    }

    /// Rotate anonymousId. Called after logOut to start a fresh anonymous session.
    func rotateAnonymousId() {
        let new = UUIDv7.next().uuidString
        defaults.set(new, forKey: Self.anonymousIdKey)
        anonymousId = new
    }
}
