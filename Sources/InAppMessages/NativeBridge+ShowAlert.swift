//
//  NativeBridge+ShowAlert.swift
//  Galva
//
//  `showAlert` bridge method — present a native `UIAlertController` on
//  behalf of the hosted page and resolve the bundle's Promise with the
//  tapped action's id.
//
//  Surface:
//    • `handleShowAlert(payload:)` — entry point dispatched from
//       `NativeBridge.handle(envelope:)` for the `.showAlert` method.
//    • `ParsedAlert`, `parseAlert(_:)` — pure parsing exposed for unit
//       tests via `@testable import Galva`.
//
//  Local to this file: `presentingViewController()` (responder-chain
//  ascent from the WebView), `alertString` / `alertStyle` parse helpers,
//  and `AlertContinuationGate` (resume-once continuation wrapper that
//  guarantees the bridge's dispatch Task never hangs even when UIKit
//  cascade-dismisses the alert without firing any action handler).
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)

extension NativeBridge {

    /// Present a system `UIAlertController` on behalf of the hosted page.
    ///
    /// Wire payload:
    ///     {
    ///       "title":   "Delete draft?",      // optional
    ///       "message": "This can't be undone", // optional
    ///       "actions": [                       // required, non-empty
    ///         { "id": "delete", "title": "Delete", "style": "destructive" },
    ///         { "id": "cancel", "title": "Cancel", "style": "cancel" }
    ///       ]
    ///     }
    ///
    /// `style` is `"default"` (the default), `"cancel"`, or `"destructive"`.
    /// UIKit permits at most one cancel action, so 2+ are rejected as
    /// `invalidPayload` rather than crashing the host app.
    ///
    /// The call suspends until the user taps an action, then resolves with
    /// `{ "actionId": "<the tapped action's id>" }`. If the in-app message
    /// sheet is dismissed while the alert is up — UIKit cascades the
    /// dismiss to the alert without firing any action handler — the
    /// continuation still resumes (via `AlertContinuationGate`'s deinit)
    /// with a `noActiveMessage` failure, so the bridge's dispatch Task
    /// never hangs and the bundle's Promise rejects cleanly.
    func handleShowAlert(
        payload: [String: AnyJSONValue]?
    ) async -> Result<AnyJSONValue?, BridgeError> {
        let parsed: ParsedAlert
        switch Self.parseAlert(payload) {
        case .success(let value): parsed = value
        case .failure(let error): return .failure(error)
        }
        guard let presenter = presentingViewController() else {
            return .failure(BridgeError(
                code: .noActiveMessage,
                message: "No view controller available to present the alert"
            ))
        }
        logger.info(.identity, "bridge showAlert", metadata: [
            "actions": String(parsed.actions.count),
        ])
        // `AlertContinuationGate` ties the continuation's lifetime to the
        // alert's action closures — when the alert dies (user tap OR
        // cascade-dismiss by the parent sheet), the gate's deinit ensures
        // the continuation is resumed exactly once. Returns `nil` only if
        // the alert went away without an action firing.
        let actionId: String? = await withCheckedContinuation { continuation in
            let gate = AlertContinuationGate(continuation: continuation)
            let alert = UIAlertController(
                title: parsed.title,
                message: parsed.message,
                preferredStyle: .alert
            )
            for action in parsed.actions {
                alert.addAction(UIAlertAction(title: action.title, style: action.style) { _ in
                    gate.resume(with: action.id)
                })
            }
            presenter.present(alert, animated: true)
            // `gate` is captured by each action closure; the alert retains
            // its actions until dealloc, so the gate outlives the alert
            // and its deinit-fallback fires on cascade-dismiss.
        }
        guard let actionId else {
            return .failure(BridgeError(
                code: .noActiveMessage,
                message: "Alert was dismissed before any action was tapped"
            ))
        }
        return .success(.object(Self.toJSON(BridgeAlertResult(actionId: actionId))))
    }

    /// Parsed, validated `showAlert` request. Internal (not private) so the
    /// pure parse logic can be unit-tested without presenting UIKit.
    struct ParsedAlert: Equatable {
        let title: String?
        let message: String?
        let actions: [Action]

        struct Action: Equatable {
            let id: String
            let title: String
            let style: UIAlertAction.Style
        }
    }

    static func parseAlert(
        _ payload: [String: AnyJSONValue]?
    ) -> Result<ParsedAlert, BridgeError> {
        guard let payload else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "showAlert requires a payload"))
        }
        // title / message are optional; a non-string value is treated as absent.
        let title = Self.alertString(payload["title"])
        let message = Self.alertString(payload["message"])

        guard case .array(let rawActions)? = payload["actions"], !rawActions.isEmpty else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "showAlert requires a non-empty actions array"))
        }
        var actions: [ParsedAlert.Action] = []
        for raw in rawActions {
            guard case .object(let object) = raw else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "showAlert action must be an object"))
            }
            guard let id = Self.alertString(object["id"]), !id.isEmpty else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "showAlert action requires a non-empty id"))
            }
            guard let actionTitle = Self.alertString(object["title"]), !actionTitle.isEmpty else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "showAlert action requires a non-empty title"))
            }
            actions.append(.init(id: id, title: actionTitle, style: Self.alertStyle(object["style"])))
        }
        // UIKit raises an exception if more than one `.cancel` action is added —
        // reject that here so a bundle bug can't crash the host app.
        guard actions.filter({ $0.style == .cancel }).count <= 1 else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "showAlert allows at most one cancel action"))
        }
        return .success(ParsedAlert(title: title, message: message, actions: actions))
    }

    private static func alertString(_ value: AnyJSONValue?) -> String? {
        if case .string(let string)? = value { return string } else { return nil }
    }

    private static func alertStyle(_ value: AnyJSONValue?) -> UIAlertAction.Style {
        guard case .string(let raw)? = value else { return .default }
        switch raw.lowercased() {
        case "cancel":      return .cancel
        case "destructive": return .destructive
        default:            return .default
        }
    }

    /// The view controller to present an alert from: the WebView's owning VC
    /// (via the responder chain), descended to its top-most presented VC so
    /// the alert layers above the in-app message sheet. Works for both the
    /// UIKit and SwiftUI hosts since both mount the WebView inside a VC.
    private func presentingViewController() -> UIViewController? {
        guard let webView = host?.webView else { return nil }
        var responder: UIResponder? = webView
        while let current = responder {
            if let viewController = current as? UIViewController {
                var top = viewController
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = current.next
        }
        return nil
    }
}

// MARK: - Alert continuation gate

/// Resume-once wrapper around a `CheckedContinuation<String?, Never>` used
/// by `handleShowAlert`. The gate is captured by every action closure on
/// the alert; UIAlertController retains its actions for its lifetime, so
/// the gate naturally outlives the alert. When the alert deallocs (user
/// tap OR parent-sheet cascade-dismiss), the captures release and the
/// gate's deinit resumes the continuation with `nil` if no action ever
/// fired. Guarantees the bridge dispatch Task awaiting the alert always
/// makes forward progress, so the bridge — and through it the WebView's
/// strong refs — can release on dismiss.
@MainActor
private final class AlertContinuationGate {
    private var continuation: CheckedContinuation<String?, Never>?

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func resume(with actionId: String) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: actionId)
    }

    deinit {
        // No isolation hop in deinit (Swift 6) — but `continuation` is
        // either nil (already resumed) or a CheckedContinuation, both of
        // which are safe to touch from any actor. The fallback resume
        // makes the alert's vanishing equivalent to a no-action tap.
        continuation?.resume(returning: nil)
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
