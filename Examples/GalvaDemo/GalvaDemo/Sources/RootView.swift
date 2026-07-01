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
import UIKit
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
                .modifier(InAppMessageRenderer(scenario: config.scenario))
        } else {
            content
        }
    }
}

/// Renders in-app messages via SwiftUI auto-display by default, or via the UIKit
/// `message.show(in:)` presenter for the `showInAppMessageUIKit` E2E scenario —
/// the presenter path the React Native wrapper drives through `showMessage`.
private struct InAppMessageRenderer: ViewModifier {
    let scenario: E2EScenario

    func body(content: Content) -> some View {
        if scenario == .showInAppMessageUIKit {
            content.modifier(UIKitPresentInAppMessages())
        } else {
            content.autoDisplayInAppMessages()
        }
    }
}

/// Presents each delivered in-app message through the UIKit `show(in:)` path so
/// the E2E exercises `InAppMessageViewController`'s safe-area timing.
private struct UIKitPresentInAppMessages: ViewModifier {
    func body(content: Content) -> some View {
        content.task {
            for await message in InAppMessages.messages {
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
                else { continue }
                try? await message.show(in: scene)
            }
        }
    }
}
