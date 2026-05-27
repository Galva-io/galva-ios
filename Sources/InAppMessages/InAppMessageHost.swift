//
//  InAppMessageHost.swift
//  Galva
//
//  Contract between `NativeBridge` and whatever is hosting the WebView
//  presentation. The bridge doesn't care whether the WebView lives inside
//  a UIKit sheet (`InAppMessagePresenter`) or a SwiftUI sheet
//  (`InAppMessageSheetCoordinator`) — it only needs to:
//
//      • Read the `WKWebView` to post `evaluateJavaScript` responses.
//      • Read safe-area insets for `getPageContext().safeArea`.
//      • Tell the host to reveal the WebView when the bundle calls
//        `galva.ready()` (anti-flash).
//      • Tell the host to dismiss the presentation when the bundle calls
//        `galva.dismiss(reason?)`.
//
//  Both hosts conform to this protocol; the bridge holds a `weak var
//  host: (any InAppMessageHost)?` reference.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)

/// Pair returned by `SDKCore.prepareInAppMessage(_:host:)` — the SwiftUI
/// coordinator mounts the `webView` inside a `UIViewRepresentable` and
/// retains the `bridge` strongly for the lifetime of the sheet (the
/// `WKUserContentController.add(_:name:)` reference to the bridge is
/// weak, so dropping the bridge tears the channel down).
///
/// `@unchecked Sendable` because both `WKWebView` and `NativeBridge` are
/// `@MainActor`-isolated reference types — passing the pointer across
/// actor boundaries is safe; method calls still respect the isolation.
struct PreparedInAppMessage: @unchecked Sendable {
    let webView: WKWebView
    let bridge: NativeBridge
}

/// What `NativeBridge` needs from its presentation owner. Both
/// `InAppMessagePresenter` (UIKit sheet via `present(animated:)`) and
/// `InAppMessageSheetCoordinator` (SwiftUI `.sheet(item:)` content)
/// conform to this — the bridge stays platform-agnostic.
///
/// Marked `Sendable` so `any InAppMessageHost` values can cross from
/// `SDKCore`'s `@GalvaActor` context into the `MainActor.run` block
/// where the WebView + bridge are built. Conformers must be `@MainActor`
/// (the protocol-level annotation enforces this) which makes the
/// reference itself safe to send; method calls on the existential still
/// respect the `@MainActor` isolation.
@MainActor
protocol InAppMessageHost: AnyObject, Sendable {
    /// `WKWebView` the bridge writes responses into via
    /// `evaluateJavaScript("window.handleNativeMessage(…)")`. Returning
    /// `nil` short-circuits the response (bridge logs + drops the call).
    var webView: WKWebView? { get }

    /// Safe-area insets surfaced to the hosted page via
    /// `galva.getPageContext().safeArea`. Hosts compute from whatever
    /// view they own (UIKit VC's view, or the SwiftUI sheet's host view).
    /// Return `.zero` when the host has nothing to measure yet.
    var safeAreaInsets: UIEdgeInsets { get }

    /// Bundle called `galva.ready()` — reveal the WebView. Idempotent.
    /// In UIKit this unhides the WebView inside the already-presented
    /// sheet; in SwiftUI this flips a `@Published` flag so the view
    /// switches from the loading placeholder to the WebView.
    func reveal()

    /// Bundle called `galva.dismiss(reason?)` — close the presentation.
    /// In UIKit this calls `dismiss(animated:)` on the presenting VC;
    /// in SwiftUI this clears the `@Binding` that drives the sheet, which
    /// triggers SwiftUI to dismiss.
    func dismiss(reason: String?)
}

#endif // canImport(WebKit) && canImport(UIKit)
