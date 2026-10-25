//
//  DemoPresentation.swift
//  GalvaDemo
//
//  How each E2E scenario presents in-app messages. Real apps pick one mode;
//  the demo covers all three paths a host app can take:
//
//    • `.automatic` (default) — the SDK presents messages itself.
//    • `.manual` + `message.show(in:)` — a UIKit presentation, the path the
//      React Native wrapper drives.
//    • `.manual` + `.inAppMessageSheet` — a SwiftUI presentation, fed by the
//      handler through `MessageCenter`.
//

import SwiftUI
import UIKit
import Galva

enum DemoPresentation {

    static func mode(for scenario: E2EScenario) -> InAppMessages.Presentation {
        switch scenario {
        case .showInAppMessageUIKit:
            return .manual { message in
                guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive })
                else { return }
                try? await message.show(in: scene)
            }
        case .showInAppMessageSwiftUISheet:
            return .manual { message in
                MessageCenter.shared.message = message
            }
        default:
            return .automatic
        }
    }
}

/// Holds the message the manual handler hands over, for `.inAppMessageSheet`
/// to present.
@MainActor
final class MessageCenter: ObservableObject {
    static let shared = MessageCenter()
    @Published var message: InAppMessages.Message?
}
