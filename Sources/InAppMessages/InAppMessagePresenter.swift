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
//      • bridge.dismiss(reason:), or a page that can't load (the
//        navigation policy) → dismiss(animated:) → teardown
//      • the app dismisses the sheet, or a VC under it → VC delegate →
//        teardown (no dismiss call needed; UIKit already took the sheet
//        off screen)
//
//  Single-presentation invariant
//      The SDK keeps at most one sheet alive. show(message:in:) calls run
//      one at a time, in call order (`InAppMessagePresentationQueue`). A
//      call for the id already on screen or queued is a no-op (per docs);
//      a call for a different id waits its turn, then dismisses the
//      current sheet first.
//
//  Bounded waits
//      UIKit doesn't call a transition's completion when it refuses the
//      transition (host mid-transition, being dismissed, already
//      presenting). `show` presents only on a view controller that can take
//      it, and every wait on UIKit gives up after `presentTimeout`.
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

    /// Runs `show` calls one at a time, in call order.
    private let showQueue = InAppMessagePresentationQueue()

    /// How long `show` waits on UIKit — for a view controller it can present
    /// on, then for the presentation to finish — and how long a dismiss
    /// waits. Past it, `show` tears the sheet down and throws
    /// `noPresentingViewController`.
    var presentTimeout: TimeInterval = 5

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
    /// Idempotent on the same message id (on screen or in flight); with a
    /// different id it waits for the show in flight, then replaces the
    /// sheet on screen.
    ///
    /// - Parameters:
    ///   - message: The message to render.
    ///   - scene: the scene to present on. Pass `nil` (the default, used by
    ///     the deep-link path) to present on the app's active window scene
    ///     (`activeWindowScene()`), resolved here on the main actor — that way callers
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
        if currentMessageId == message.id || showQueue.contains(message.id) {
            logger.debug(.identity, "show(in:) ignored — message already presenting",
                         metadata: ["messageId": message.id])
            return
        }
        // One at a time: each show suspends (resolve, download, present),
        // and two interleaved would both present.
        try await showQueue.run(id: message.id) {
            try await performShow(
                message: message,
                in: scene,
                prefetchedProducts: prefetchedProducts,
                deepLinkParameters: deepLinkParameters
            )
        }
    }

    private func performShow(
        message: InAppMessages.Message,
        in scene: UIWindowScene?,
        prefetchedProducts: [String: AnyJSONValue],
        deepLinkParameters: [String: String]
    ) async throws {
        guard let scene = scene ?? Self.activeWindowScene() else {
            logger.warning(.identity, "show(in:) — no foreground UIWindowScene to present on",
                           metadata: ["messageId": message.id])
            throw InAppMessageError.noPresentingViewController
        }

        if currentMessageId != nil {
            logger.info(.identity, "show(in:) dismissing previous overlay",
                        metadata: ["replacedBy": message.id])
            await dismissAnimated(reason: "replaced")
        }

        // Note: exclusion with the polling pipeline lives UPSTREAM — the
        // caller (SDKCore.showInAppMessage) claims the manager's display slot
        // before this runs, which suppresses in-app message fetching for the
        // whole flight. By the time we present, no concurrently-polled
        // message can exist.

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

        // 3. Wait for a host VC UIKit will present on.
        let deadline = ProcessInfo.processInfo.systemUptime + presentTimeout
        guard await readyHost(in: scene, until: deadline) != nil else {
            logger.warning(.identity, "show(in:) — no host VC ready to present on",
                           metadata: ["messageId": message.id])
            throw InAppMessageError.noPresentingViewController
        }

        // 4. Build the WebView + bridge + VC. Inject the StoreKit product
        //    summary as `window.galvaProducts` before any bundle script
        //    runs so offer screens have pricing without an extra fetch.
        currentMessageId = message.id
        let (webView, bridge) = makeWebViewAndBridge(
            messageId: message.id,
            bundleURL: bundleURL,
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
        self.viewController = vc

        // 5. Present on the topmost VC as it is now — the app may have
        //    presented something during the hop above.
        guard let host = await readyHost(in: scene, until: deadline) else {
            logger.warning(.identity, "show(in:) — no host VC ready to present on",
                           metadata: ["messageId": message.id])
            await discard(vc)
            throw InAppMessageError.noPresentingViewController
        }
        logger.info(.identity, "show(in:) presenting sheet", metadata: [
            "messageId": message.id,
            "version": version,
            "host": String(describing: type(of: host)),
        ])
        let presented = await Self.waitForUIKit(until: deadline) { done in
            host.present(vc, animated: true) { done() }
        }
        guard presented else {
            logger.warning(.identity, "show(in:) — sheet not presented in time",
                           metadata: ["messageId": message.id])
            await discard(vc)
            throw InAppMessageError.noPresentingViewController
        }

        // 6. On screen: only now mark the message active, which also marks
        //    it presented — so every failure above leaves it deliverable.
        await messageManager.setActiveMessageId(message.id)
        // Gone again during that hop: it was shown, but isn't active.
        if viewController !== vc {
            await messageManager.setActiveMessageId(nil)
        }
    }

    // MARK: - Reveal / Dismiss (called by bridge and navigation policy)

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
        messageId: String,
        bundleURL: URL,
        prefetchedProducts: [String: AnyJSONValue],
        deepLinkParameters: [String: String]
    ) -> (WKWebView, NativeBridge) {
        // Both UIKit and SwiftUI presentation paths share the same
        // WebView + bridge construction; the factory keeps the two in
        // lockstep without copy-paste drift.
        #if canImport(StoreKit)
        return InAppMessageWebViewFactory.make(
            messageId: messageId,
            bundleURL: bundleURL,
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
            messageId: messageId,
            bundleURL: bundleURL,
            messageManager: messageManager,
            identity: identity,
            host: self,
            prefetchedProducts: prefetchedProducts,
            deepLinkParameters: deepLinkParameters,
            logger: logger
        )
        #endif
    }

    /// Start a UIKit transition and wait for its completion until
    /// `deadline`. `present` / `dismiss` are callback-based, and UIKit
    /// doesn't call the completion for a transition it refuses — an
    /// unbounded wait would hang `show`, and the automatic presentation loop
    /// behind it. Returns `false` at the deadline.
    private static func waitForUIKit(
        until deadline: TimeInterval,
        _ start: (@escaping @Sendable () -> Void) -> Void
    ) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let latch = CompletionLatch(cont)
            Task { @MainActor in
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                latch.finish(false)
            }
            start { latch.finish(true) }
        }
    }

    /// The topmost VC in `scene` once UIKit can present on it, checking
    /// until `deadline` — the app's own transition usually finishes in well
    /// under a second. `nil` if none is ready by then.
    private func readyHost(in scene: UIWindowScene, until deadline: TimeInterval) async -> UIViewController? {
        while true {
            if let host = topViewController(for: scene), Self.canPresent(on: host) {
                return host
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return nil
            }
        }
    }

    /// Whether UIKit will take a presentation on `host` now: it's in a
    /// window, isn't mid-transition or being dismissed, and isn't already
    /// presenting something.
    static func canPresent(on host: UIViewController) -> Bool {
        host.viewIfLoaded?.window != nil
            && host.transitionCoordinator == nil
            && !host.isBeingPresented
            && !host.isBeingDismissed
            && host.presentedViewController == nil
    }

    private func dismissAnimated(reason: String?) async {
        guard let vc = viewController else { return }
        logger.info(.identity, "overlay dismissed", metadata: [
            "messageId": currentMessageId ?? "<none>",
            "reason": reason ?? "<unspecified>",
        ])
        // Our own dismiss — the VC mustn't report it as removed by the app.
        vc.delegate = nil
        // If we're already detached from a window the system has dropped
        // the modal — skip the animated dismiss and go straight to
        // teardown so we don't await a callback that never fires. Dismiss
        // from the presenting VC, so anything the bundle put over the sheet
        // (a `showAlert` alert) goes with it.
        if let presenting = vc.presentingViewController, !vc.isBeingDismissed {
            let deadline = ProcessInfo.processInfo.systemUptime + presentTimeout
            let dismissed = await Self.waitForUIKit(until: deadline) { done in
                presenting.dismiss(animated: true) { done() }
            }
            if !dismissed {
                // Still up: at least let the user swipe it away.
                vc.isModalInPresentation = false
            }
        }
        await teardown(vc, reason: reason)
    }

    /// Give up on a sheet UIKit hasn't presented: tear it down, and if
    /// UIKit presents it after all, have it dismiss itself rather than sit
    /// on screen blank.
    private func discard(_ vc: InAppMessageViewController) async {
        vc.isDiscarded = true
        vc.isModalInPresentation = false
        vc.delegate = nil
        await teardown(vc, reason: "not_presented")
    }

    /// Drop every reference to `vc`'s presentation, if it's still the
    /// current one — a late callback for a replaced sheet must not tear
    /// down its successor. Idempotent.
    ///
    /// Calls `InAppMessageWebViewFactory.tearDown(webView:bridge:)` first
    /// so every native-side edge into the WebView (both script-message
    /// handlers, navigation/UI delegates, the bridge's strong console-
    /// handler ref) is gone before we drop our strong refs to the VC and
    /// bridge. That guarantees the WebView — the heaviest object in the
    /// presentation — is releasable the instant UIKit lets go of the VC,
    /// even if a bridge dispatch Task is still in flight elsewhere.
    private func teardown(_ vc: InAppMessageViewController, reason: String?) async {
        guard viewController === vc else { return }
        InAppMessageWebViewFactory.tearDown(webView: vc.webView, bridge: bridge)
        viewController = nil
        bridge = nil
        currentMessageId = nil
        await messageManager.setActiveMessageId(nil)
        _ = reason
    }

    // MARK: - Host VC discovery

    /// The app window scene to present on (`preferredScene`). Used by the
    /// deep-link and automatic paths, which have no developer-supplied
    /// scene. MainActor-isolated — the presenter is `@MainActor`, so
    /// reading `UIApplication.shared` here is safe.
    static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return preferredScene(among: scenes) { scene in
            SceneTraits(
                isApplicationWindow: scene.session.role == .windowApplication,
                isForegroundActive: scene.activationState == .foregroundActive,
                hasKeyWindow: scene.windows.contains { $0.isKeyWindow }
            )
        }
    }

    /// What `preferredScene` weighs about a scene.
    struct SceneTraits {
        /// `.windowApplication` session role — not an external display's.
        var isApplicationWindow: Bool
        var isForegroundActive: Bool
        var hasKeyWindow: Bool
    }

    /// The scene to present on: an app window scene (never an external
    /// display's), preferring a foreground-active one with a key window,
    /// then any foreground-active one, then any. Generic over the scene so
    /// the choice is testable without UIKit scenes.
    static func preferredScene<Scene>(among scenes: [Scene], traits: (Scene) -> SceneTraits) -> Scene? {
        let candidates = scenes
            .map { (scene: $0, traits: traits($0)) }
            .filter { $0.traits.isApplicationWindow }
        let choice = candidates.first { $0.traits.isForegroundActive && $0.traits.hasKeyWindow }
            ?? candidates.first { $0.traits.isForegroundActive }
            ?? candidates.first
        return choice?.scene
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

// MARK: - InAppMessageViewControllerDelegate (removed without the SDK)

extension InAppMessagePresenter: InAppMessageViewControllerDelegate {
    func inAppMessageViewControllerDidDisappear(
        _ controller: InAppMessageViewController
    ) {
        // The app dismissed the sheet, or a VC under it. UIKit already took
        // it off screen — just drop the presentation.
        Task { @MainActor in
            await self.teardown(controller, reason: "removed_by_app")
        }
    }
}

// MARK: - Bounded UIKit waits

/// Resumes `waitForUIKit`'s continuation once — with UIKit's completion or
/// at the deadline, whichever comes first. Lock-protected so the
/// completion can fire from whatever context UIKit calls it on.
private final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ completed: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: completed)
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
