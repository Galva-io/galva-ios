//
//  InAppMessage.swift
//  Galva
//
//  Public `InAppMessages.Message` envelope — the value type developers
//  consume off the `InAppMessages.messages` AsyncStream.
//
//  Deliberately small. The full content (copy, layout, components,
//  theming) lives inside the WebView bundle keyed by `webviewVersion`; the
//  host app never inspects it. Developers typically read `id` and
//  `workflowType`, then call `message.show(in: scene)` to render.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public extension InAppMessages {

    /// A single pending in-app message addressed to the current identity.
    /// Receive these through `InAppMessages.messages` and pass them back to
    /// `InAppMessages.show(_:in:)` to render.
    struct Message: Sendable, Hashable, Identifiable {

        /// Server-generated communication id. Stable for the lifetime of
        /// the workflow run that produced the message; safe to use as a
        /// dedupe key.
        public let id: String

        /// Workflow that triggered this message, when known. `nil` for
        /// broadcast or manual sends that don't belong to a lifecycle
        /// workflow.
        public let workflowType: WorkflowType?

        /// When the server queued the message. Useful for sorting display
        /// order client-side when the developer chooses to coalesce a
        /// burst of foreground polls.
        public let createdAt: Date


        public init(
            id: String,
            workflowType: WorkflowType?,
            createdAt: Date
        ) {
            self.id = id
            self.workflowType = workflowType
            self.createdAt = createdAt
        }
    }

    /// The recovery flow that sent a message.
    ///
    /// Galva adds flow types over time. A message from a type this SDK
    /// version doesn't know still arrives, carrying the server's raw value,
    /// so compare with the known values or switch with a `default` case:
    ///
    ///     switch message.workflowType {
    ///     case .trialRescue?:          showTrialTheme()
    ///     case .cancellationRecovery?: showSaveTheme()
    ///     default:                     showDefaultTheme()
    ///     }
    ///
    /// A struct rather than an enum, so adding a type never breaks your build.
    struct WorkflowType: RawRepresentable, Sendable, Hashable, CaseIterable, CustomStringConvertible {

        /// The server's identifier for the flow type, e.g. `"trial-rescue"`.
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Trial Recovery: trials about to end without converting.
        public static let trialRescue = WorkflowType(rawValue: "trial-rescue")
        /// Subscription Recovery, shown as Cancellation Recovery in the
        /// dashboard: subscribers who turned off auto-renew.
        public static let cancellationRecovery = WorkflowType(rawValue: "cancellation-recovery")
        /// Win-Back: subscribers whose subscription has lapsed.
        public static let winback = WorkflowType(rawValue: "winback")
        /// Failed-payment recovery.
        public static let paymentRecovery = WorkflowType(rawValue: "payment-recovery")

        /// The flow types this SDK version knows. Messages can carry others.
        public static let allCases: [WorkflowType] = [
            .trialRescue, .cancellationRecovery, .winback, .paymentRecovery,
        ]

        public var description: String { rawValue }
    }

    /// How in-app messages reach the screen. Pass it to
    /// `Galva.configure(apiKey:…, inAppMessages:)`.
    enum Presentation: Sendable {

        /// Galva presents each message itself, as a sheet on your app's
        /// active window, as soon as it's ready. The default.
        case automatic

        /// Galva hands each message to `handler` on the main actor and
        /// presents nothing itself. Your app decides when and where the
        /// message appears, for example with `message.show(in:)`:
        ///
        ///     Galva.configure(apiKey: "pk_your_app_id", inAppMessages: .manual { message in
        ///         guard let scene = myActiveWindowScene() else { return }
        ///         try? await message.show(in: scene)
        ///     })
        ///
        /// Messages arrive one at a time: the next one waits until
        /// `handler` returns. They're also published on
        /// `InAppMessages.messages`, so SwiftUI apps can present them with
        /// `.inAppMessageSheet(_:)` instead — present each message in one
        /// place only.
        case manual(handler: @MainActor @Sendable (InAppMessages.Message) async -> Void)
    }
}

// MARK: - Rendering

#if canImport(UIKit) && canImport(WebKit)

public extension InAppMessages.Message {

    /// Present the message as a sheet on the topmost view controller in
    /// `scene`. The SDK builds a `WKWebView` configured with the native
    /// bridge, loads the cached HTML bundle for this message's webview
    /// version, and presents a managed view controller via
    /// `present(_:animated:completion:)`. Idempotent — calling `show` a
    /// second time with the same message is a no-op while it is on screen.
    ///
    /// Use this from your `for await message in InAppMessages.messages`
    /// loop:
    ///
    ///     Task { @MainActor in
    ///         for await message in InAppMessages.messages {
    ///             guard let scene = UIApplication.shared
    ///                 .connectedScenes
    ///                 .first(where: { $0.activationState == .foregroundActive })
    ///                 as? UIWindowScene
    ///             else { continue }
    ///             try? await message.show(in: scene)
    ///         }
    ///     }
    ///
    /// - Throws: `InAppMessages.Error.notConfigured` if `Galva.configure`
    ///   hasn't run, `.messageNotFound` if the server says the message is
    ///   no longer valid (workflow exited / invalidated), or
    ///   `.bundleUnavailable` if the WebView bundle for the resolved
    ///   version can't be downloaded and isn't cached on disk.
    func show(in scene: UIWindowScene) async throws {
        try await SDKCore.shared.showInAppMessage(self, in: scene)
    }
}

#endif

// MARK: - Wire → public bridges (internal)

extension CommunicationItem {
    /// Lift a wire-format communication into the public envelope. Filters
    /// to in-app variants are applied upstream; this mapping accepts any
    /// type so future channels don't crash an older SDK.
    func toPublicMessage() -> InAppMessages.Message {
        InAppMessages.Message(
            id: id.uuidString.lowercased(),
            workflowType: workflowType.map(InAppMessages.WorkflowType.init(rawValue:)),
            createdAt: createdAt
        )
    }
}
