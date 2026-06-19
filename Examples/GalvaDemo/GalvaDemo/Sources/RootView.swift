//
//  RootView.swift
//  GalvaDemo
//
//  The canonical SDK integration, exactly as a host app would write it:
//  one `.galvaConfigure(...)` to configure the SDK + auto-attach deep-link
//  forwarding, and one `.autoDisplayInAppMessages()` to render retention
//  messages with zero extra wiring.
//

import SwiftUI
import Galva

struct RootView: View {
    let config: E2EConfig

    var body: some View {
        ControlPanelView()
            .galvaConfigure(
                apiKey: config.apiKey,
                environment: config.environment,
                logLevel: .debug
            )
            .autoDisplayInAppMessages()
    }
}
