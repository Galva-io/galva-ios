//
//  DemoPresentation.swift
//  GalvaDemo
//
//  How each E2E scenario presents in-app messages. Real apps pick one mode;
//  the demo covers all three paths a host app can take:
//
//    • `.automatic` (default) — the SDK presents messages itself.
//    • `.manual` + UIKit — the app reads `InAppMessages.messages` and calls
//      `message.show(in:)`, the presenter the React Native wrapper drives.
//    • `.manual` + SwiftUI — the app reads the stream into `@State` and
//      presents it with `.inAppMessageSheet`.
//
//  `RootView` holds the two manual loops.
//

import Galva

enum DemoPresentation {

    static func mode(for scenario: E2EScenario) -> InAppMessages.Presentation {
        switch scenario {
        case .showInAppMessageUIKit, .showInAppMessageSwiftUISheet:
            return .manual
        default:
            return .automatic
        }
    }
}
