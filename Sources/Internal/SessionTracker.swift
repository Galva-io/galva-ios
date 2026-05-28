//
//  SessionTracker.swift
//  Galva
//
//  Auto-tracks `session_start` events. Enabled by passing `.lifecycle`
//  in `autoTrackCategories` on `Galva.configure(...)`.
//
//  Session rules (see /sdk/overview/#session-tracking):
//      • Cold start             → emit `session_start` immediately.
//      • Foreground after 30+ minutes of background inactivity → emit.
//      • Foreground within 30 minutes → no-op (session continues).
//      • No `session_end` event — duration is computed server-side from
//        successive `session_start` timestamps.
//
//  Event properties are built by `ContextProvider.sessionProperties()` so
//  they're derived from the same snapshot / bundle / library values that
//  populate every message's `context` envelope. A session_start's properties
//  therefore never disagree with the `context` on its own message:
//      • device_locale  — `Locale.current.identifier`
//      • os_version     — `context.os.version` (`UIDevice.systemVersion`)
//      • app_version    — `CFBundleShortVersionString` from Info.plist
//      • sdk_version    — `SDKConstants.version`
//
//  `device_country` is intentionally NOT included on the wire — the
//  server derives it from the request IP, which is more reliable than
//  the device's Region setting (especially for travelers).
//
//  Persistence:
//      `lastSessionStart` is stored in UserDefaults so the 30-minute
//      window survives app kills. The next process launch reads it
//      back on construction and applies the same rule.
//
//  Opt-out:
//      An `isOptedOut` closure is injected at construction so the
//      tracker can early-return without bumping the persisted
//      timestamp. Bumping the timestamp during opt-out would cause the
//      next legitimate `session_start` (after the user opts back in) to
//      be suppressed by the 30-minute rule.
//

import Foundation

@GalvaActor
final class SessionTracker {

    /// 30-minute window per the SDK overview.
    static let sessionWindow: TimeInterval = 30 * 60

    /// `UserDefaults` key for the persisted timestamp.
    static let lastSessionStartKey = "co.galva.lastSessionStartAt"

    /// Most recent `session_start` we emitted. `nil` on first install
    /// (cold-start path is taken).
    private(set) var lastSessionStart: Date?

    private let defaults: UserDefaults
    private let logger: any GalvaLogger

    /// Same provider that builds the `context` envelope for every outgoing
    /// message. Reused here so the `session_start` property bag stays
    /// consistent with that context (one source of truth for
    /// device/app/os/locale/sdk values). Held by value — `ContextProvider`
    /// is `Sendable` and its `DeviceSnapshot` is immutable post-configure,
    /// and session properties don't read the mutable device token.
    private let contextProvider: ContextProvider

    /// `() -> Bool` injected so tests can flip opt-out without touching
    /// the SDKCore singleton. In production this closure reads
    /// `SDKCore.shared.isOptedOut` through the lock-protected mirror.
    private let isOptedOut: @Sendable () -> Bool

    /// `@GalvaActor` async closure that hands the event to the SDK's
    /// message queue via `SDKCore.track(event:properties:)`. The
    /// indirection keeps the tracker testable — tests pass a
    /// `RecordingTrackHandler` that captures emissions.
    private let trackHandler: @GalvaActor (String, [String: AnyJSONValue]?) async -> Void

    init(
        defaults: UserDefaults = .standard,
        logger: any GalvaLogger,
        contextProvider: ContextProvider = ContextProvider(),
        isOptedOut: @escaping @Sendable () -> Bool,
        trackHandler: @escaping @GalvaActor (String, [String: AnyJSONValue]?) async -> Void
    ) {
        self.defaults = defaults
        self.logger = logger
        self.contextProvider = contextProvider
        self.isOptedOut = isOptedOut
        self.trackHandler = trackHandler
        // Load persisted timestamp so the 30-minute window survives
        // app restarts.
        if let stored = defaults.object(forKey: Self.lastSessionStartKey) as? Date {
            self.lastSessionStart = stored
        }
    }

    /// Called on every foreground transition (and once on cold start)
    /// by the lifecycle observer. Decides whether to emit a
    /// `session_start` based on the 30-minute rule + opt-out check.
    /// Idempotent within the same window.
    func handleForeground(now: Date = Date()) async {
        // Hard skip when opted out — and crucially, DON'T bump the
        // persisted timestamp. Otherwise the next legitimate
        // foreground (after opt-out is lifted) would be suppressed by
        // the 30-minute rule because of a "phantom" session_start that
        // was never actually emitted.
        guard !isOptedOut() else {
            logger.debug(.lifecycle, "session foreground skipped (opted out)")
            return
        }

        if let last = lastSessionStart, now.timeIntervalSince(last) < Self.sessionWindow {
            logger.debug(.lifecycle, "session continues — within window", metadata: [
                "secondsSinceLastSession": String(format: "%.0f", now.timeIntervalSince(last)),
            ])
            return
        }

        // Either cold start (lastSessionStart == nil) or the 30-minute
        // window has elapsed — emit a fresh session. Capture the cold-start
        // state BEFORE the assignment below, otherwise the log always reads
        // "false" (lastSessionStart is non-nil by the time it's evaluated).
        let isColdStart = (lastSessionStart == nil)
        lastSessionStart = now
        defaults.set(now, forKey: Self.lastSessionStartKey)
        logger.info(.lifecycle, "session_start", metadata: [
            "coldStart": isColdStart ? "true" : "false",
        ])

        await trackHandler("session_start", contextProvider.sessionProperties())
    }

    /// Test helper — drops the persisted timestamp so the next
    /// `handleForeground` always takes the cold-start path.
    func reset() {
        lastSessionStart = nil
        defaults.removeObject(forKey: Self.lastSessionStartKey)
    }
}
