//
//  RootView.swift
//  GalvaDemo
//
//  The canonical SDK integration, exactly as a host app would write it:
//  one `.galvaConfigure(...)` to configure the SDK + auto-attach deep-link
//  forwarding, and one `.autoDisplayInAppMessages()` to render retention
//  messages with zero extra wiring.
//
//  In the performance baseline (`config.sdkEnabled == false`) the integration
//  is skipped entirely, so the perf suite can measure the host shell with no
//  Galva involvement and report the SDK's cost as a delta.
//

import SwiftUI
import Galva

struct RootView: View {
    let config: E2EConfig

    var body: some View {
        ControlPanelView()
            .modifier(GalvaIntegration(config: config))
    }
}

/// Applies the SDK integration only when enabled. A `@ViewBuilder` body lets
/// the two branches return different concrete view types.
private struct GalvaIntegration: ViewModifier {
    let config: E2EConfig

    func body(content: Content) -> some View {
        if config.sdkEnabled {
            content
                .galvaConfigure(
                    apiKey: config.apiKey,
                    environment: config.environment,
                    logLevel: .debug
                )
                .autoDisplayInAppMessages()
        } else {
            content
        }
    }
}
