//
//  InAppMessageNavigationPolicy.swift
//  Galva
//
//  The in-app message WebView's navigation + UI delegate. Installed by
//  `InAppMessageWebViewFactory`, so the UIKit sheet and the SwiftUI sheet
//  make the same decisions:
//      • The WebView navigates only to the bundle's own file. Anything else
//        (a network page, another local file, an iframe) is cancelled —
//        links go through the `galva.openDeepLink` bridge instead — so no
//        other page ever runs with the `galva` bridge installed.
//      • A page that fails to load, or whose web content process dies,
//        closes the presentation (`host.dismiss`) instead of leaving a
//        blank sheet the user can't swipe away.
//      • JavaScript alerts from the bundle are suppressed.
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
final class InAppMessageNavigationPolicy: NSObject {

    /// File URL of the bundle the WebView loads — the one page it may show.
    let bundleURL: URL

    let logger: any GalvaLogger

    /// The presentation to close when the page can't be shown. Weak, like
    /// the bridge's.
    weak var host: (any InAppMessageHost)?

    init(bundleURL: URL, logger: any GalvaLogger) {
        self.bundleURL = bundleURL
        self.logger = logger
    }

    /// Whether `url` is the bundle file itself — the only page the WebView
    /// may navigate to.
    static func isBundlePage(_ url: URL?, bundleURL: URL) -> Bool {
        guard let url else { return false }
        return url.scheme == "file" && url.path == bundleURL.path
    }

    /// Whether a failed navigation leaves the page unusable. A navigation
    /// cancelled by a newer one, or by teardown's `stopLoading()`, doesn't.
    static func isFatal(_ error: any Error) -> Bool {
        let error = error as NSError
        return !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
    }

    private func close(reason: String) {
        host?.dismiss(reason: reason)
    }
}

// MARK: - WKNavigationDelegate (bundle allowlist + load failures)

extension InAppMessageNavigationPolicy: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        // `@MainActor` matches the WKNavigationDelegate optional
        // requirement's closure isolation in iOS 18+ SDKs. Without it
        // Swift 6 emits a "nearly matches" warning that prevents the
        // optional-requirement satisfaction from binding cleanly.
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let target = navigationAction.request.url
        if Self.isBundlePage(target, bundleURL: bundleURL) {
            decisionHandler(.allow)
            return
        }
        logger.warning(.inAppMessages, "webview navigation blocked", metadata: [
            "url": target?.loggableLocation ?? "<nil>",
        ])
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard Self.isFatal(error) else { return }
        logger.warning(.inAppMessages, "webview navigation failed", error: error)
        close(reason: "load_failed")
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard Self.isFatal(error) else { return }
        logger.warning(.inAppMessages, "webview provisional navigation failed", error: error)
        close(reason: "load_failed")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.warning(.inAppMessages, "webview content process terminated")
        close(reason: "web_process_terminated")
    }
}

// MARK: - WKUIDelegate (suppress bundle-initiated JS alerts)

extension InAppMessageNavigationPolicy: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        // `@MainActor` to match the WKUIDelegate optional requirement's
        // closure isolation in iOS 18+ SDKs (same reason as the nav
        // delegate's decisionHandler above).
        completionHandler: @escaping @MainActor () -> Void
    ) {
        logger.warning(.inAppMessages, "bundle attempted JS alert (suppressed)",
                       metadata: ["message": message])
        completionHandler()
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
