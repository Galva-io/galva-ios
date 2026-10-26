//
//  InAppMessageViewController.swift
//  Galva
//
//  The view controller that hosts the WKWebView for a single in-app
//  message. Owned by `InAppMessagePresenter`, presented as a sheet via
//  `present(animated:)` on the host app's topmost view controller.
//
//  Why a dedicated VC instead of a free-floating UIWindow overlay:
//      • UIKit's modal presentation lifecycle (viewDidAppear,
//        viewDidDisappear) gives us clean hooks for setup + teardown.
//      • Sheets render with the system's standard chrome (corner
//        radius, dim-out behind) without us re-implementing any of it.
//        The grabber is suppressed and swipe-to-dismiss is disabled
//        (`isModalInPresentation = true`) so the bundle's own CTA /
//        `galva.dismiss()` is the only path out. A page that can't load
//        closes the sheet through `InAppMessageNavigationPolicy`.
//      • Lives in the host scene's window hierarchy, so accessibility
//        focus and system gestures (Reachability, Stage Manager) behave
//        the same as any other app modal.
//
//  The WebView's navigation + UI delegate is the shared
//  `InAppMessageNavigationPolicy` (installed by the factory), not this VC.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)

/// Notified by the VC when the sheet leaves the screen without the SDK
/// dismissing it — the app dismissed it, or a view controller under it
/// (e.g. a SwiftUI sheet whose `isPresented` went false). The presenter
/// uses it to drop the presentation. The SDK's own dismiss detaches the
/// delegate first.
@MainActor
protocol InAppMessageViewControllerDelegate: AnyObject {
    func inAppMessageViewControllerDidDisappear(
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

    /// File URL of the HTML bundle, loaded once the sheet appears.
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

    /// True once we've kicked off the bundle load. The load is deferred to
    /// `viewDidAppear` (see below), and this guards against a re-appear
    /// reloading it.
    private var didLoadBundle = false

    /// Set by the presenter when it gives up on this sheet (UIKit didn't
    /// present it in time) and tears it down. If UIKit shows it anyway, it
    /// dismisses itself instead of sitting on screen blank.
    var isDiscarded = false

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
        // NOTE: the bundle is deliberately NOT loaded here. Loading in
        // viewDidLoad lets the page boot and call `getPageContext()` before the
        // sheet is laid out in its window, so it reads `safeAreaInsets == .zero`
        // (no notch / home-indicator padding) — worst on a cached bundle that
        // boots fast. The load is deferred to `viewDidAppear`, once the
        // presentation — and its safe area — is settled.
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isDiscarded else {
            logger.info(.inAppMessages, "iam VC appeared after it was discarded — dismissing",
                        metadata: ["messageId": messageId])
            (presentingViewController ?? self).dismiss(animated: true)
            return
        }

        // Load the bundle now that the sheet is on screen and laid out — its
        // safe area is final, so the page's first `getPageContext()` reads the
        // real insets. Guarded so a re-appear never reloads.
        guard !didLoadBundle else { return }
        didLoadBundle = true
        webView.loadFileURL(
            bundleURL,
            allowingReadAccessTo: bundleURL.deletingLastPathComponent()
        )
        logger.debug(.inAppMessages, "iam VC viewDidAppear — bundle loadFileURL",
                     metadata: ["messageId": messageId])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Gone for good — not just covered by something presented over it.
        guard isLeavingPresentation else { return }
        logger.info(.inAppMessages, "iam VC removed from screen", metadata: ["messageId": messageId])
        delegate?.inAppMessageViewControllerDidDisappear(self)
    }

    /// Whether this sheet is leaving its presentation: being dismissed,
    /// already detached from its presenter, or going down with a view
    /// controller under it that's being dismissed.
    private var isLeavingPresentation: Bool {
        if isBeingDismissed || presentingViewController == nil { return true }
        var ancestor = presentingViewController
        while let vc = ancestor {
            if vc.isBeingDismissed { return true }
            ancestor = vc.presentingViewController
        }
        return false
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
        logger.debug(.inAppMessages, "iam VC revealed", metadata: ["messageId": messageId])
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

#endif // canImport(WebKit) && canImport(UIKit)
