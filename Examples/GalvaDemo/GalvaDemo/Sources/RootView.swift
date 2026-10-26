//
//  RootView.swift
//  GalvaDemo
//
//  The canonical SDK integration, exactly as a host app would write it:
//  `GalvaDemoApp` calls `Galva.configure` once at launch — the SDK presents
//  in-app messages on its own — and the root view forwards Galva links with
//  `onOpenURL`.
//
//  The two `.manual` E2E scenarios read `InAppMessages.messages` here and
//  present each message themselves (see `DemoPresentation`).
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
/// the branches return different concrete view types.
private struct GalvaIntegration: ViewModifier {
    let config: E2EConfig
    @State private var message: InAppMessages.Message?

    func body(content: Content) -> some View {
        if !config.sdkEnabled {
            content
        } else {
            switch config.scenario {
            case .showInAppMessageSwiftUISheet:
                // `.manual` + SwiftUI: read the stream into state, present it
                // with `.inAppMessageSheet`.
                content
                    .onOpenURL { url in Galva.handleOpenURL(url) }
                    .task {
                        for await incoming in InAppMessages.messages {
                            message = incoming
                        }
                    }
                    .inAppMessageSheet($message)
            case .showInAppMessageUIKit:
                // `.manual` + UIKit: present each message with `show(in:)` on
                // the foreground scene — the path the React Native wrapper
                // drives. (`.automatic` already covers the SDK's own scene
                // lookup, `message.show()` with no scene.)
                content
                    .onOpenURL { url in Galva.handleOpenURL(url) }
                    .task {
                        for await message in InAppMessages.messages {
                            let scene = UIApplication.shared.connectedScenes
                                .compactMap { $0 as? UIWindowScene }
                                .first { $0.activationState == .foregroundActive }
                            try? await message.show(in: scene)
                        }
                    }
            default:
                content
                    .onOpenURL { url in Galva.handleOpenURL(url) }
            }
        }
    }
}
