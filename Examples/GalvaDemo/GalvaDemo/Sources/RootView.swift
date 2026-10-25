//
//  RootView.swift
//  GalvaDemo
//
//  The canonical SDK integration, exactly as a host app would write it:
//  `GalvaDemoApp` calls `Galva.configure` once at launch — the SDK presents
//  in-app messages on its own — and the root view forwards Galva links with
//  `onOpenURL`.
//
//  The SwiftUI-sheet E2E scenario configures `.manual` presentation and
//  presents through `.inAppMessageSheet` here (see `DemoPresentation`).
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
/// the branches return different concrete view types.
private struct GalvaIntegration: ViewModifier {
    let config: E2EConfig
    @ObservedObject private var messageCenter = MessageCenter.shared

    func body(content: Content) -> some View {
        if !config.sdkEnabled {
            content
        } else if config.scenario == .showInAppMessageSwiftUISheet {
            content
                .onOpenURL { url in Galva.handleOpenURL(url) }
                .inAppMessageSheet($messageCenter.message)
        } else {
            content
                .onOpenURL { url in Galva.handleOpenURL(url) }
        }
    }
}
