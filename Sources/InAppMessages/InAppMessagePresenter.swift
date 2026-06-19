//
//  InAppMessagePresenter.swift
//  Galva
//
//  Coordinator that wires up an `InAppMessageViewController` for a single
//  in-app message and presents it as a sheet on the host app's topmost
//  view controller using `present(_:animated:completion:)`.
//
//  Why sheet instead of a dedicated UIWindow overlay:
//      • Standard UIKit modal presentation gives us proper lifecycle
//        hooks (viewWillAppear, viewDidDisappear), animated in/out,
//        interactive swipe-to-dismiss, and the system sheet chrome.
//      • Living inside the host's window hierarchy means accessibility
//        focus, Stage Manager, and OS-level gestures behave the same as
//        any other app modal.
//      • The dedicated VC owns the WebView, so its lifetime is bounded
//        by UIKit's presentation lifetime — no manual UIWindow juggling.
//
//  Lifecycle
//      • show(message:in:) → resolve → build VC → present(animated:)
//      • bridge.ready() → presenter.reveal() → VC unhides the WebView
//      • bridge.dismiss(reason:) → dismiss(animated:) → teardown
//      • user swipes sheet down → VC delegate → teardown (no dismiss
//        call needed; UIKit already dismissed the sheet)
//
//  Single-presentation invariant
//      The SDK keeps at most one sheet alive. A second show(_:in:) for
//      the same id is a no-op (per docs); a show(_:in:) for a different
//      id while another is on screen dismisses the current one first.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)

@MainActor
final class InAppMessagePresenter: NSObject {

    let messageManager: InAppMessageManager
    let identity: IdentityStore
    let bundleCache: WebViewBundleCache
    let logger: any GalvaLogger

    #if canImport(StoreKit)
    /// Optional StoreKit warm-cache routed into the bridge so a
    /// `requestPurchase` call can resolve the `Product` without a
    /// round-trip when the SDK already fetched the SKU.
    let storeKitPrefetcher: StoreKitProductPrefetcher?
    #endif

    /// Currently-presented VC, if any. Owned strongly so it stays alive
    /// for the lifetime of the presentation; dropped on dismiss.
    private(set) var viewController: InAppMessageViewController?

    /// Bridge installed on the active VC's WebView. Kept here so the
    /// WebView's weak script-handler reference stays valid.
    private var bridge: NativeBridge?

    /// ID of the message currently being presented. Used to dedupe
    /// duplicate `show()` calls and to clear `activeMessageId` on
    /// teardown.
    private var currentMessageId: String?

    /// Convenience accessors used by `NativeBridge` to reach UIKit state
    /// it doesn't own.
    var webView: WKWebView? { viewController?.webView }
    var window: UIWindow? { viewController?.view.window }

    #if canImport(StoreKit)
    init(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        bundleCache: WebViewBundleCache,
        storeKitPrefetcher: StoreKitProductPrefetcher?,
        logger: any GalvaLogger
    ) {
        self.messageManager = messageManager
        self.identity = identity
        self.bundleCache = bundleCache
        self.storeKitPrefetcher = storeKitPrefetcher
        self.logger = logger
    }
    #else
    init(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        bundleCache: WebViewBundleCache,
        logger: any GalvaLogger
    ) {
        self.messageManager = messageManager
        self.identity = identity
        self.bundleCache = bundleCache
        self.logger = logger
    }
    #endif

    // MARK: - Show

    /// Show `message` as a sheet on the topmost VC in `scene`.
    /// Idempotent on the same message id; replaces an in-flight
    /// presentation when called with a different id.
    ///
    /// - Parameters:
    ///   - message: The message to render.
    ///   - scene: the scene to present on. Pass `nil` (the default, used by
    ///     the deep-link path) to present on the app's foreground-active
    ///     `UIWindowScene`, resolved here on the main actor — that way callers
    ///     that don't already hold a scene (e.g. a `gv://` URL open) don't have
    ///     to send a non-`Sendable` `UIWindowScene` across an actor hop.
    ///   - prefetchedProducts: StoreKit product summary keyed by `productId`,
    ///     as structured `AnyJSONValue`s. Injected into the WebView as
    ///     `window.galvaProducts` at `.atDocumentStart` so the bundle has
    ///     localized pricing + display copy before any of its own JavaScript
    ///     runs. Pass `[:]` when nothing's pre-fetched — the bundle handles an
    ///     empty catalog. Serialized to JSON by the factory, not the caller.
    ///   - deepLinkParameters: the originating deep link's query parameters,
    ///     injected as `window.galvaDeepLinkParams`. `[:]` for the normal
    ///     stream-driven path (no originating URL).
    func show(
        message: InAppMessages.Message,
        in scene: UIWindowScene? = nil,
        prefetchedProducts: [String: AnyJSONValue] = [:],
        deepLinkParameters: [String: String] = [:]
    ) async throws {
        guard let scene = scene ?? Self.activeWindowScene() else {
            logger.warning(.identity, "show(in:) — no foreground UIWindowScene to present on",
                           metadata: ["messageId": message.id])
            throw InAppMessageError.notConfigured
        }
        if currentMessageId == message.id {
            logger.debug(.identity, "show(in:) ignored — message already presenting",
                         metadata: ["messageId": message.id])
            return
        }
        
        if currentMessageId != nil {
            logger.info(.identity, "show(in:) dismissing previous overlay",
                        metadata: ["replacedBy": message.id])
            await dismissAnimated(reason: "replaced")
        }

        // 1. Resolve payload (server pin → /sdk/initialize fallback for
        //    the webview version). The bridge serves the payload back to
        //    the bundle via `getMessageData()`.
        let resolved = try await messageManager.resolve(messageId: message.id)
        guard let resolved else {
            logger.warning(.identity, "show(in:) — server returned invalid",
                           metadata: ["messageId": message.id])
            throw InAppMessageError.messageNotFound
        }
        let version = resolved.webviewVersion

        // 2. Resolve the bundle (download from S3 on cache miss).
        let bundleURL: URL
        do {
            bundleURL = try await bundleCache.bundleURL(for: version)
        } catch {
            logger.warning(.identity, "show(in:) bundle download failed",
                           metadata: ["version": version],
                           error: error)
            throw InAppMessageError.bundleUnavailable
        }

        // 3. Build the WebView + bridge + VC. Inject the StoreKit product
        //    summary as `window.galvaProducts` before any bundle script
        //    runs so offer screens have pricing without an extra fetch.
        await messageManager.setActiveMessageId(message.id)
        currentMessageId = message.id
        let (webView, bridge) = makeWebViewAndBridge(
            prefetchedProducts: prefetchedProducts,
            deepLinkParameters: deepLinkParameters
        )
        self.bridge = bridge
        let vc = InAppMessageViewController(
            webView: webView,
            bundleURL: bundleURL,
            messageId: message.id,
            logger: logger
        )
        vc.delegate = self
        webView.navigationDelegate = vc
        webView.uiDelegate = vc
        self.viewController = vc

        // 4. Find the host VC and present.
        guard let host = topViewController(for: scene) else {
            logger.warning(.identity, "show(in:) — no host VC in scene")
            await teardown(reason: "no_host")
            throw InAppMessageError.notConfigured
        }
        logger.info(.identity, "show(in:) presenting sheet", metadata: [
            "messageId": message.id,
            "version": version,
            "host": String(describing: type(of: host)),
        ])
        await present(vc, on: host)
    }

    // MARK: - Reveal / Dismiss (called by bridge)

    func reveal() {
        viewController?.revealWebView()
    }

    func dismiss(reason: String?) {
        Task { @MainActor in
            await self.dismissAnimated(reason: reason)
        }
    }

    // MARK: - Internals

    private func makeWebViewAndBridge(
        prefetchedProducts: [String: AnyJSONValue],
        deepLinkParameters: [String: String]
    ) -> (WKWebView, NativeBridge) {
        // Both UIKit and SwiftUI presentation paths share the same
        // WebView + bridge construction; the factory keeps the two in
        // lockstep without copy-paste drift.
        #if canImport(StoreKit)
        return InAppMessageWebViewFactory.make(
            messageManager: messageManager,
            identity: identity,
            storeKitPrefetcher: storeKitPrefetcher,
            host: self,
            prefetchedProducts: prefetchedProducts,
            deepLinkParameters: deepLinkParameters,
            logger: logger
        )
        #else
        return InAppMessageWebViewFactory.make(
            messageManager: messageManager,
            identity: identity,
            host: self,
            prefetchedProducts: prefetchedProducts,
            deepLinkParameters: deepLinkParameters,
            logger: logger
        )
        #endif
    }

    /// `present(_:animated:completion:)` is callback-based — wrap it in a
    /// continuation so the show() flow remains a clean `async` path.
    private func present(_ vc: UIViewController, on host: UIViewController) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            host.present(vc, animated: true) {
                cont.resume()
            }
        }
    }

    private func dismissAnimated(reason: String?) async {
        guard let vc = viewController else { return }
        logger.info(.identity, "overlay dismissed", metadata: [
            "messageId": currentMessageId ?? "<none>",
            "reason": reason ?? "<unspecified>",
        ])
        // If we're already detached from a window the system has dropped
        // the modal — skip the animated dismiss and go straight to
        // teardown so we don't await a callback that never fires.
        if vc.presentingViewController != nil {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                vc.dismiss(animated: true) {
                    cont.resume()
                }
            }
        }
        await teardown(reason: reason)
    }

    /// Drop every reference to the active presentation. Idempotent.
    ///
    /// Calls `InAppMessageWebViewFactory.tearDown(webView:bridge:)` first
    /// so every native-side edge into the WebView (both script-message
    /// handlers, navigation/UI delegates, the bridge's strong console-
    /// handler ref) is gone before we drop our strong refs to the VC and
    /// bridge. That guarantees the WebView — the heaviest object in the
    /// presentation — is releasable the instant UIKit lets go of the VC,
    /// even if a bridge dispatch Task is still in flight elsewhere.
    private func teardown(reason: String?) async {
        if let webView = viewController?.webView {
            InAppMessageWebViewFactory.tearDown(webView: webView, bridge: bridge)
        }
        viewController = nil
        bridge = nil
        currentMessageId = nil
        await messageManager.setActiveMessageId(nil)
        _ = reason
    }

    // MARK: - Host VC discovery

    /// The app's foreground-active window scene (falling back to any
    /// connected window scene). Used by the deep-link path, which has no
    /// developer-supplied scene. MainActor-isolated — the presenter is
    /// `@MainActor`, so reading `UIApplication.shared` here is safe.
    static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func topViewController(for scene: UIWindowScene) -> UIViewController? {
        let keyWindow = scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
        guard let root = keyWindow?.rootViewController else { return nil }
        return topMostViewController(from: root)
    }

    private func topMostViewController(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topMostViewController(from: presented)
        }
        if let nav = vc as? UINavigationController, let visible = nav.visibleViewController {
            return topMostViewController(from: visible)
        }
        if let tab = vc as? UITabBarController, let selected = tab.selectedViewController {
            return topMostViewController(from: selected)
        }
        return vc
    }
}

// MARK: - InAppMessageViewControllerDelegate (non-programmatic dismiss)

extension InAppMessagePresenter: InAppMessageViewControllerDelegate {
    func inAppMessageViewControllerDidInteractivelyDismiss(
        _ controller: InAppMessageViewController
    ) {
        // Swipe-to-dismiss is blocked via `isModalInPresentation`, so the
        // only path here is a WebView navigation failure. Treat it like
        // any other unsolicited teardown.
        Task { @MainActor in
            await self.teardown(reason: "user_dismissed")
        }
    }
}

// MARK: - InAppMessageHost

extension InAppMessagePresenter: InAppMessageHost {
    /// Read insets from the VC's view, which reflects the *presented
    /// sheet's* safe area (grabber, corner radius, dynamic island, home
    /// indicator) rather than the under-sheet host window. Returns
    /// `.zero` before the VC is on screen.
    var safeAreaInsets: UIEdgeInsets {
        viewController?.view.safeAreaInsets ?? .zero
    }
    // `webView`, `reveal()`, and `dismiss(reason:)` are already defined
    // on the type above; the host conformance picks them up directly.
}

#endif // canImport(WebKit) && canImport(UIKit)
