//
//  NotificationResponse.swift
//  Galva
//
//  Pure helpers behind `Galva.userNotificationCenter(_:didReceive:)`. Kept
//  free of any `UserNotifications` type (they take plain Foundation values) so
//  the gate + attribute-building logic is unit-testable on the host without
//  fabricating a `UNNotificationResponse` (which has no public initializer).
//

import Foundation

enum NotificationResponse {

    /// `userInfo` key + value that marks an APNs payload as Galva-originated.
    /// Single source of truth — change here if the backend marker changes.
    static let senderKey = "sender"
    static let senderValue = "galva"

    /// `true` when the notification's `userInfo` carries the Galva sender
    /// marker (`"sender": "galva"`, case-insensitive). The host app's own
    /// notifications lack it and are ignored.
    static func isFromGalva(_ userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[senderKey] as? String)?.lowercased() == senderValue
    }

    /// Flat attribute bag for a notification interaction event: the full
    /// `userInfo` body (string-keyed) plus `id` = the notification's request
    /// identifier. `id` is set last, so the notification id always wins over a
    /// `userInfo` key literally named `id`. Non-string `userInfo` keys (rare in
    /// APNs) are dropped; value coercion to JSON happens later in
    /// `AppEvents.track` via `AnyJSONValue.coercing(dictionary:)`.
    static func attributes(id: String, userInfo: [AnyHashable: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(userInfo.count + 1)
        for (key, value) in userInfo {
            if let key = key as? String { out[key] = value }
        }
        out["id"] = id
        return out
    }
}
