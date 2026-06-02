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

        /// Raw server-side channel/type discriminator (e.g.
        /// `"trial-rescue-in-app"`). Surfaced for logging — the typed
        /// `workflowType` is the supported way to branch on workflow.
        public let rawType: String

        public init(
            id: String,
            workflowType: WorkflowType?,
            createdAt: Date,
            rawType: String
        ) {
            self.id = id
            self.workflowType = workflowType
            self.createdAt = createdAt
            self.rawType = rawType
        }
    }

    /// Workflow categories surfaced by the server. New cases will be added
    /// over time; switch on this enum with a `@unknown default` branch.
    enum WorkflowType: String, Sendable, Hashable, CaseIterable {
        /// Pre-churn (subscriber rescue) save offer.
        case prechurnSave    = "prechurn-save"
        /// Failed-payment recovery.
        case paymentRecovery = "payment-recovery"
        /// Trial-to-paid conversion rescue.
        case trialRescue     = "trial-rescue"
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
            workflowType: workflowType?.toPublic(),
            createdAt: createdAt,
            rawType: type.rawValue
        )
    }
}

extension CommunicationItem.WorkflowType {
    func toPublic() -> InAppMessages.WorkflowType {
        switch self {
        case .prechurnSave:    return .prechurnSave
        case .paymentRecovery: return .paymentRecovery
        case .trialRescue:     return .trialRescue
        }
    }
}
