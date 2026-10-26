//
//  AppLifecycleObserver.swift
//  Galva
//
//  Single source of truth for "the app just became active" events.
//
//  Per the in-app messaging docs, we poll only on these triggers:
//      • App open (cold start)
//      • Every time the app becomes active again — a return from the
//        background, and also Control Center, a Face ID / permission prompt
//        or a call banner closing
//  …and *never* on a recurring timer. Each activation is a chance to refresh
//  in-app messages instead of polling for them. This observer collapses the
//  triggers into one `onForeground` callback for the message manager.
//
//  Why NotificationCenter instead of an @MainActor SwiftUI hook: SDK code
//  has no scene/window guarantees on cold start, and SwiftUI scenePhase
//  isn't observable from a library. Notifications work whether the host
//  app is UIKit, SwiftUI, or mixed.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Listens for app-activation events and invokes `onForeground` on the
/// main actor each time one fires.
@MainActor
final class AppLifecycleObserver {

    private var observers: [NSObjectProtocol] = []
    private let center: NotificationCenter
    private let didBecomeActive: Notification.Name?
    private let onForeground: @Sendable () -> Void

    /// `onForeground` is called once on `start()` (cold start) and again on
    /// every `didBecomeActive`. `center` and `didBecomeActive` are injectable
    /// so tests can drive the observer on a private center; without a
    /// `didBecomeActive` name (macOS) only the cold-start event fires.
    init(
        center: NotificationCenter = .default,
        didBecomeActive: Notification.Name? = AppLifecycleObserver.applicationDidBecomeActive,
        onForeground: @escaping @Sendable () -> Void
    ) {
        self.center = center
        self.didBecomeActive = didBecomeActive
        self.onForeground = onForeground
    }

    /// UIApplication's didBecomeActive; `nil` where there is none (macOS).
    nonisolated static var applicationDidBecomeActive: Notification.Name? {
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.didBecomeActiveNotification
        #else
        nil
        #endif
    }

    /// Wire up notifications and emit an initial foreground event for
    /// cold-start polling. Idempotent — calling twice does nothing the
    /// second time.
    func start() {
        guard observers.isEmpty else { return }
        if let didBecomeActive {
            // didBecomeActive is the cleanest "fully foreground" signal; we
            // use it as the only wakeup. willEnterForeground would fire even
            // for partial entries that get yanked back to background by the
            // OS (multitasking previews on iPad). didBecomeActive doesn't.
            let token = center.addObserver(
                forName: didBecomeActive,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `queue: .main` guarantees we're on the main thread, so it's
                // safe to assert MainActor isolation. Swift 6 can't infer this
                // from the NotificationCenter Sendable closure signature.
                MainActor.assumeIsolated { self?.fire() }
            }
            observers.append(token)
        }
        // Emit an immediate foreground event so cold-start polling lines up
        // with the rest of the configure() path. Defer one runloop tick so
        // the message manager has a chance to attach its stream consumers.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
    }

    func stop() {
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
    }

    // No deinit cleanup. The observer is owned by SDKCore for the SDK's
    // lifetime; in production it never deinits. If a test instance does,
    // the tokens become unreachable references on NotificationCenter —
    // those are tiny and the test process exits shortly after.

    private func fire() {
        onForeground()
    }
}
