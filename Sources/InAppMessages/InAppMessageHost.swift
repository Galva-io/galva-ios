//
//  InAppMessageHost.swift
//  Galva
//
//  Contract between `NativeBridge` and whatever is hosting the WebView
//  presentation. The bridge doesn't care whether the WebView lives inside
//  a UIKit sheet (`InAppMessagePresenter`) or a SwiftUI sheet
//  (`InAppMessagePresentationCoordinator`) — it only needs to:
//
//      • Read the `WKWebView` to post `evaluateJavaScript` responses.
//      • Read safe-area insets for `getPageContext().safeArea`.
//      • Tell the host to reveal the WebView when the bundle calls
//        `galva.ready()` (anti-flash).
//      • Tell the host to dismiss the presentation when the bundle calls
//        `galva.dismiss(reason?)` — or, from the WebView's navigation
//        policy, when the page can't load or its process dies.
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
/// coordinator mounts the `webView` inside a `UIViewRepresentable` and keeps
/// the `bridge` for the lifetime of the sheet. WebKit retains the bridge
/// strongly as the script-message handler; the coordinator holds it to hand
/// to `InAppMessageWebViewFactory.tearDown(webView:bridge:)`, which removes
/// that handler on dismiss.
///
/// `@unchecked Sendable` because both `WKWebView` and `NativeBridge` are
/// `@MainActor`-isolated reference types — passing the pointer across
/// actor boundaries is safe; method calls still respect the isolation.
struct PreparedInAppMessage: @unchecked Sendable {
    let webView: WKWebView
    let bridge: NativeBridge
    /// HTML bundle to load. The SwiftUI coordinator loads it from the sheet's
    /// `onAppear` (not at prepare time) so the page boots — and reads
    /// `getPageContext().safeArea` — only once the WebView is in the sheet's
    /// window, where safe-area insets are valid.
    let bundleURL: URL
}

/// What `NativeBridge` needs from its presentation owner. Both
/// `InAppMessagePresenter` (UIKit sheet via `present(animated:)`) and
/// `InAppMessagePresentationCoordinator` (drives the SwiftUI
/// `.sheet(item:)`) conform to this — the bridge stays platform-agnostic.
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

    /// Bundle called `galva.dismiss(reason?)`, or its page failed to load
    /// or its web content process died (`InAppMessageNavigationPolicy`) —
    /// close the presentation.
    /// In UIKit this calls `dismiss(animated:)` on the presenting VC;
    /// in SwiftUI this clears the `@Binding` that drives the sheet, which
    /// triggers SwiftUI to dismiss.
    func dismiss(reason: String?)
}

#endif // canImport(WebKit) && canImport(UIKit)
