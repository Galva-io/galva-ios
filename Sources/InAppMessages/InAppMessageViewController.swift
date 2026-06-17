//
//  InAppMessageViewController.swift
//  Galva
//
//  The view controller that hosts the WKWebView for a single in-app
//  message. Owned by `InAppMessagePresenter`, presented as a sheet via
//  `present(animated:)` on the host app's topmost view controller.
//
//  Why a dedicated VC instead of a free-floating UIWindow overlay:
//      • UIKit's modal presentation lifecycle (viewWillAppear,
//        viewDidDisappear, presentationControllerDidDismiss) gives us
//        clean hooks for setup + teardown.
//      • Sheets render with the system's standard chrome (corner
//        radius, dim-out behind) without us re-implementing any of it.
//        The grabber is suppressed and swipe-to-dismiss is disabled
//        (`isModalInPresentation = true`) so the bundle's own CTA /
//        `galva.dismiss()` is the only path out — the
//        adaptive-presentation delegate stays wired for WebView
//        navigation-failure teardown.
//      • Lives in the host scene's window hierarchy, so accessibility
//        focus and system gestures (Reachability, Stage Manager) behave
//        the same as any other app modal.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)

/// Notified by the VC when the sheet goes away outside the
/// programmatic `dismiss(reason:)` path — only WebView load failures,
/// now that swipe-to-dismiss is blocked by `isModalInPresentation`.
/// The presenter uses it to clean up state on those failure paths.
@MainActor
protocol InAppMessageViewControllerDelegate: AnyObject {
    func inAppMessageViewControllerDidInteractivelyDismiss(
        _ controller: InAppMessageViewController
    )
}

@MainActor
final class InAppMessageViewController: UIViewController {

    /// WebView we own. Stored on the VC (not the presenter) so the
    /// VC controls its full lifetime — `deinit` ensures the
    /// `WKScriptMessageHandler` is removed even if the presenter is
    /// dropped before us.
    let webView: WKWebView

    /// File URL of the loaded HTML bundle. Used as the navigation
    /// allowlist key.
    let bundleURL: URL

    /// Server-side message id this VC is presenting. Bridge calls use it
    /// to validate `activeMessageId`.
    let messageId: String

    /// Logger inherited from SDKCore.
    let logger: any GalvaLogger

    weak var delegate: InAppMessageViewControllerDelegate?

    /// True once the bundle has called `galva.ready()` and we've revealed
    /// the WebView. Idempotent — repeated reveal calls are no-ops.
    private(set) var hasRevealed: Bool = false

    init(
        webView: WKWebView,
        bundleURL: URL,
        messageId: String,
        logger: any GalvaLogger
    ) {
        self.webView = webView
        self.bundleURL = bundleURL
        self.messageId = messageId
        self.logger = logger
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .pageSheet
        // Block swipe-to-dismiss: the bundle owns the dismiss surface
        // (CTA, close button, `galva.dismiss()`), so the system swipe
        // shouldn't take the message down out from under it.
        self.isModalInPresentation = true
        if let sheet = sheetPresentationController {
            // Single large detent keeps the bundle in charge of its own
            // layout — multi-detent sheets force the bundle to redo its
            // layout mid-gesture, which the v1 bundle isn't designed for.
            sheet.detents = [.large()]
            sheet.preferredCornerRadius = 16
        }
    }

    // UIViewController requires `init?(coder:)`; the `@available(*, unavailable)`
    // annotation blocks compile-time callers, and this VC is never decoded from
    // a Storyboard / NSCoder. The crash is only reachable via reflection-based
    // instantiation, which we treat as a programmer error.
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable — use init(webView:bundleURL:messageId:logger:)") } // galva-lint:disable reason="required NSCoding stub, @available(*, unavailable) blocks compile-time use"

    // MARK: - Lifecycle

    override func loadView() {
        // The VC's view is just a container. The WebView fills it.
        let container = UIView()
        container.backgroundColor = .systemBackground
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installWebView()
        // Hidden until the bundle calls galva.ready() so we never flash
        // unstyled content. The sheet's chrome (background + grabber)
        // animates in regardless.
        webView.isHidden = true
        webView.loadFileURL(
            bundleURL,
            allowingReadAccessTo: bundleURL.deletingLastPathComponent()
        )
        logger.debug(.identity, "iam VC viewDidLoad — bundle loadFileURL",
                     metadata: ["messageId": messageId])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Hook the adaptive-presentation delegate here (not in init)
        // because `presentationController` is only non-nil once the
        // VC is attached to a presentation.
        presentationController?.delegate = self
    }

    // No deinit cleanup. The presenter's `teardown()` removes the
    // `WKScriptMessageHandler` on the dismissal path; WKWebView
    // releases its `WKUserContentController` when the WebView itself
    // is deallocated, which detaches any lingering handlers naturally.
    // Avoiding deinit cleanup also keeps Swift 6 strict concurrency
    // happy — nonisolated deinit cannot touch MainActor state on the
    // WebView config without an explicit isolation hop we can't safely
    // make from deinit.

    // MARK: - Reveal-on-ready

    /// Invoked by the bridge when the bundle calls `galva.ready()`.
    /// Idempotent.
    func revealWebView() {
        guard !hasRevealed else { return }
        hasRevealed = true
        webView.isHidden = false
        logger.debug(.identity, "iam VC revealed", metadata: ["messageId": messageId])
    }

    // MARK: - Layout

    private func installWebView() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate (swipe-to-dismiss)

extension InAppMessageViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        logger.info(.identity, "iam VC interactively dismissed",
                    metadata: ["messageId": messageId])
        delegate?.inAppMessageViewControllerDidInteractivelyDismiss(self)
    }
}

// MARK: - WKNavigationDelegate (file:// allowlist + load failures)

extension InAppMessageViewController: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        // `@MainActor` matches the WKNavigationDelegate optional
        // requirement's closure isolation in iOS 18+ SDKs. Without it
        // Swift 6 emits a "nearly matches" warning that prevents the
        // optional-requirement satisfaction from binding cleanly.
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Allow only the file URL we loaded. Anything else (network
        // navigation, deep link tap inside the bundle) is rerouted
        // through the explicit `galva.openDeepLink` bridge.
        if target.scheme == "file", target.path == bundleURL.path {
            decisionHandler(.allow)
            return
        }
        logger.warning(.identity, "webview navigation blocked", metadata: [
            "url": target.absoluteString,
        ])
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        logger.warning(.identity, "webview navigation failed", error: error)
        delegate?.inAppMessageViewControllerDidInteractivelyDismiss(self)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        logger.warning(.identity, "webview provisional navigation failed", error: error)
        delegate?.inAppMessageViewControllerDidInteractivelyDismiss(self)
    }
}

// MARK: - WKUIDelegate (suppress bundle-initiated JS alerts)

extension InAppMessageViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        // `@MainActor` to match the WKUIDelegate optional requirement's
        // closure isolation in iOS 18+ SDKs (same reason as the nav
        // delegate's decisionHandler above).
        completionHandler: @escaping @MainActor () -> Void
    ) {
        logger.warning(.identity, "bundle attempted JS alert (suppressed)",
                       metadata: ["message": message])
        completionHandler()
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
