//
//  Galva+Notifications.swift
//  Galva
//
//  Forwarder for `UNUserNotificationCenterDelegate` responses. When the user
//  taps or dismisses a **Galva** push, the SDK tracks it as a built-in event
//  (`$gv_notification_tapped` / `$gv_notification_dismissed`) carrying the
//  notification id + the full APNs `userInfo` body.
//
//  Like the device-token + deep-link forwarders, this mirrors the delegate
//  signature so wiring is one line — and Galva never takes ownership of your
//  delegate (no swizzling). Only notifications carrying the Galva marker
//  (`"sender": "galva"`) are tracked; your app's own notifications pass
//  through untouched.
//
//      func userNotificationCenter(_ center: UNUserNotificationCenter,
//          didReceive response: UNNotificationResponse,
//          withCompletionHandler completionHandler: @escaping () -> Void) {
//          Galva.userNotificationCenter(center, didReceive: response)
//          completionHandler()
//      }
//

import Foundation

#if canImport(UserNotifications)
import UserNotifications

public extension Galva {

    /// Forward a notification response from
    /// `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    /// Tracks `$gv_notification_tapped` (default tap) or
    /// `$gv_notification_dismissed` (system dismiss) for Galva-originated
    /// notifications, with the notification id + full `userInfo` as attributes.
    /// Custom action-button responses are ignored.
    ///
    /// - Returns: `true` if Galva tracked an event for this response; `false`
    ///   when it isn't a Galva notification or isn't a tap/dismiss (so the
    ///   call is safe to use as a bare statement).
    @discardableResult
    static func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) -> Bool {
        let request = response.notification.request
        let userInfo = request.content.userInfo

        guard NotificationResponse.isFromGalva(userInfo) else { return false }

        let eventName: String
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            eventName = NotificationEvent.tapped
        case UNNotificationDismissActionIdentifier:
            eventName = NotificationEvent.dismissed
        default:
            // Custom action buttons aren't tracked.
            return false
        }

        // The body is the arbitrary APNs payload, so track dynamically — the
        // predictable `id` is enforced by `attributes(id:userInfo:)`. The dict
        // is built synchronously (no non-Sendable userInfo crosses an actor).
        AppEvents.track(
            eventName,
            attributes: NotificationResponse.attributes(id: request.identifier, userInfo: userInfo)
        )
        return true
    }
}

#endif // canImport(UserNotifications)
