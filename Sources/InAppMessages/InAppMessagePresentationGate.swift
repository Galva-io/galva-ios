//
//  InAppMessagePresentationGate.swift
//  Galva
//
//  Process-wide, MainActor-isolated gate ensuring only ONE in-app message is
//  presented at a time — across BOTH presentation paths:
//
//      • the UIKit `InAppMessagePresenter` used by deep links
//        (`openCommunication`) and the public `message.show(in:)`, and
//      • the SwiftUI `.autoDisplayInAppMessages()` / `.inAppMessageSheet`
//        coordinator.
//
//  Without it, a deep-link presentation and a concurrently-polled auto-display
//  message stack on the same host ("Attempt to present … which is already
//  presenting …") and each WebView's bridge clobbers the other's state.
//
//  Priority: a *programmatic* claim (deep link / `show(in:)`, user-initiated)
//  wins — it preempts an auto-display sheet. An *auto-display* claim yields to
//  any presentation already on screen. Both are keyed on the owning host, so a
//  host replacing its OWN message (a legitimate hot-swap) is never blocked.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif

#if canImport(WebKit) && canImport(UIKit)

@MainActor
final class InAppMessagePresentationGate {

    static let shared = InAppMessagePresentationGate()
    private init() {}

    /// Message id currently presented (or claimed for imminent present). `nil`
    /// when nothing is on screen. Informational — the ownership checks key on
    /// `host` identity, not this id.
    private(set) var presentingMessageId: String?

    /// Host that owns the current presentation. Weak so a host that deallocs
    /// without releasing (shouldn't happen) frees the slot automatically.
    private weak var host: (any InAppMessageHost)?

    /// Auto-display (SwiftUI) claim. Succeeds only when the slot is free or
    /// already owned by `host` (a hot-swap to a new message on the same host).
    /// Returns `false` — the caller must yield — when a *different* host is
    /// presenting, so an auto-displayed poll message never stacks on top of a
    /// deep-link presentation.
    @discardableResult
    func claimForAutoDisplay(_ messageId: String, host: any InAppMessageHost) -> Bool {
        if let existing = self.host, existing as AnyObject !== host as AnyObject {
            return false
        }
        presentingMessageId = messageId
        self.host = host
        return true
    }

    /// Programmatic / deep-link (UIKit) claim. Always wins: it asks a
    /// *different* current host to dismiss, then takes the slot. Idempotent for
    /// the same host.
    func claimForProgrammatic(_ messageId: String, host: any InAppMessageHost) {
        if let existing = self.host, existing as AnyObject !== host as AnyObject {
            existing.dismiss(reason: "replaced")
        }
        presentingMessageId = messageId
        self.host = host
    }

    /// Release the slot if `host` currently owns it. Called from each host's
    /// teardown.
    func release(host: any InAppMessageHost) {
        if let existing = self.host, existing as AnyObject === host as AnyObject {
            presentingMessageId = nil
            self.host = nil
        }
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
