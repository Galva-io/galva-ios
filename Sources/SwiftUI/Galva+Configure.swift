//
//  Galva+Configure.swift
//  Galva
//
//  SwiftUI one-liner setup. `.galvaConfigure(apiKey:…)` on your root view
//  replaces calling `Galva.configure(...)` from `App.init()` AND wires up deep
//  linking — it attaches `onOpenURL` for you, so a SwiftUI app never has to
//  forward URL opens the way a UIKit `AppDelegate` would.
//
//      @main struct MyApp: App {
//          var body: some Scene {
//              WindowGroup {
//                  ContentView()
//                      .galvaConfigure(apiKey: "pk_live_…")
//              }
//          }
//      }
//
//  Lives in its own file gated only on `canImport(SwiftUI)` (not WebKit /
//  UIKit) so it's available to SwiftUI apps on every platform the SDK
//  supports — unlike the in-app-message modifiers, configuration + deep-link
//  forwarding have no UIKit/WebKit dependency.
//

import Foundation
#if canImport(SwiftUI)
import SwiftUI

public extension View {

    /// Configure the Galva SDK and wire up deep-link forwarding from your
    /// SwiftUI root view — the SwiftUI equivalent of calling
    /// `Galva.configure(...)` in `App.init()` plus an `onOpenURL` handler.
    ///
    /// Apply it once, on your top-level view:
    ///
    /// ```swift
    /// @main
    /// struct MyApp: App {
    ///     var body: some Scene {
    ///         WindowGroup {
    ///             ContentView()
    ///                 .galvaConfigure(apiKey: "pk_live_xxxxxxxx")
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// What it does:
    /// - Calls `Galva.configure(...)` exactly once for this view's lifetime
    ///   (configure is itself idempotent, so re-renders are safe).
    /// - Attaches `onOpenURL` and forwards every opened URL to
    ///   `Galva.handleOpenURL(_:)`. You do **not** forward deep links yourself
    ///   — Galva inspects each URL for its own payloads (e.g. offer redemption)
    ///   and ignores the rest, so your app's own routing is untouched.
    ///
    /// Parameters mirror `Galva.configure(...)`.
    func galvaConfigure(
        apiKey: String,
        environment: Galva.Environment = .production,
        autoTrackCategories: Galva.AutoTrackCategory = [.lifecycle, .appleSearchAds],
        logLevel: Galva.LogLevel = .warning,
        logger: (any GalvaLogger)? = nil
    ) -> some View {
        modifier(GalvaConfigureModifier(
            apiKey: apiKey,
            environment: environment,
            autoTrackCategories: autoTrackCategories,
            logLevel: logLevel,
            logger: logger
        ))
    }
}

/// Runs `Galva.configure(...)` once on appear and forwards `onOpenURL` to the
/// SDK. The `@State` guard keeps configure to a single call across re-appears
/// (configure is idempotent too, but the guard avoids the "configured more
/// than once" warning on benign re-renders).
private struct GalvaConfigureModifier: ViewModifier {
    let apiKey: String
    let environment: Galva.Environment
    let autoTrackCategories: Galva.AutoTrackCategory
    let logLevel: Galva.LogLevel
    let logger: (any GalvaLogger)?

    @State private var didConfigure = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didConfigure else { return }
                didConfigure = true
                Galva.configure(
                    apiKey: apiKey,
                    environment: environment,
                    autoTrackCategories: autoTrackCategories,
                    logLevel: logLevel,
                    logger: logger
                )
            }
            .onOpenURL { url in
                Galva.handleOpenURL(url)
            }
    }
}

#endif // canImport(SwiftUI)
