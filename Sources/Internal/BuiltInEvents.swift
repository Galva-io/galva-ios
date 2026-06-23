//
//  BuiltInEvents.swift
//  Galva
//
//  Single source of truth for the events the SDK emits on the app's behalf
//  (as opposed to the developer's own `AppEvents.track(...)`). Centralized here
//  so wire names + property shapes live in one place and call sites can't drift.
//
//  Two flavors, by design:
//    • Predictable properties → a typed `AppEvents.Event` whose **required**
//      init parameters are the properties, so an emission site can't forget or
//      mistype one (e.g. `SessionStartEvent`).
//    • An arbitrary JSON body (e.g. a push's APNs `userInfo`) → no typed struct;
//      tracked dynamically via `AppEvents.track(name:attributes:)`, since a
//      struct over an all-JSON payload buys no compile-time safety. Only the
//      predictable parts are enforced — for notifications, the `id`, via
//      `NotificationResponse.attributes(id:userInfo:)`. Their wire names live in
//      `NotificationEvent` below.
//

import Foundation

/// `session_start` — auto-emitted by `SessionTracker` on cold start and at the
/// start of each new session window. All properties are predictable, so they're
/// required, typed init parameters; `attributes` maps them to the `$gv`-free
/// wire keys the backend expects. Built by `ContextProvider.sessionStartEvent()`
/// from the same values that feed each message's `context` envelope.
struct SessionStartEvent: AppEvents.Event {
    let deviceLocale: String
    let osVersion: String
    let appVersion: String
    let sdkVersion: String

    var eventName: String { "session_start" }

    var attributes: EventAttributes? {
        [
            "device_locale": deviceLocale,
            "os_version": osVersion,
            "app_version": appVersion,
            "sdk_version": sdkVersion,
        ]
    }
}

/// Wire names for the notification-interaction events. These carry the
/// arbitrary APNs `userInfo` body, so they're tracked dynamically (a typed
/// struct over an all-JSON payload adds no safety); the predictable `id` is
/// enforced by `NotificationResponse.attributes(id:userInfo:)`.
enum NotificationEvent {
    static let tapped = "$gv_notification_tapped"
    static let dismissed = "$gv_notification_dismissed"
}
