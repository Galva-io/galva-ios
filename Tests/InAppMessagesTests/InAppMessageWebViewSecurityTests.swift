//
//  InAppMessageWebViewSecurityTests.swift
//  GalvaTests
//
//  The WebView both presentation paths build (`InAppMessageWebViewFactory`),
//  exercised through the SwiftUI path's `prepareInAppMessage` with real
//  WebKit pages:
//    • it navigates only to the bundle's own file — a page it was sent to
//      never gets the `galva` bridge
//    • the bridge takes messages only from the bundle's main frame, not
//      from an iframe
//    • a page that fails to load, or whose web content process dies,
//      closes the presentation instead of leaving a blank sheet; a
//      cancelled navigation doesn't
//
//  Runs on the iOS Simulator. The page-level tests have the page report to a
//  `probe` handler outside the bridge, so they know it ran; a test runner in
//  which WebKit never runs the page skips them rather than passing them
//  without checking anything.
//

import Foundation
@testable import Galva
import XCTest
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class InAppMessageWebViewSecurityTests: XCTestCase {

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    // MARK: - Navigation

    func test_pageTheBundleNavigatesTo_isBlocked_andGetsNoBridge() async throws {
        // The bundle sends the WebView to another file:// page, which calls
        // the bridge.
        let (prepared, host, harness) = try await prepare(html: """
        <html><body><script>
        webkit.messageHandlers.probe.postMessage('bundle');
        setTimeout(function () { location.href = 'other.html'; }, 0);
        </script></body></html>
        """)
        defer { harness.cleanup() }
        let directory = prepared.bundleURL.deletingLastPathComponent()
        try Self.page(posting: "dismiss").write(
            to: directory.appendingPathComponent("other.html"), atomically: true, encoding: .utf8
        )
        let probe = installProbe(on: prepared)

        load(prepared)

        try await waitForPage(probe, toReport: "bundle")
        let left = await waitUntil(within: 1.5) {
            prepared.webView.url?.lastPathComponent == "other.html" || !host.dismissReasons.isEmpty
        }
        XCTAssertFalse(left, "navigation away from the bundle must be blocked")
        XCTAssertEqual(prepared.webView.url?.path, prepared.bundleURL.path)
        XCTAssertEqual(host.dismissReasons.count, 0, "no other page may reach the bridge")
    }

    func test_bridge_ignoresMessagesFromAnIframe() async throws {
        // The main frame calls `ready` and the iframe `dismiss`, each right
        // after telling the probe it ran.
        let (prepared, host, harness) = try await prepare(html: """
        <html><body>
        <iframe srcdoc="<script>webkit.messageHandlers.probe.postMessage('frame'); webkit.messageHandlers.galva.postMessage({name: 'dismiss', requestId: 'frame', payload: {}})</script>"></iframe>
        <script>
        webkit.messageHandlers.probe.postMessage('main');
        webkit.messageHandlers.galva.postMessage({name: 'ready', requestId: 'main', payload: {}});
        </script>
        </body></html>
        """)
        defer { harness.cleanup() }
        // Let the iframe load, so this checks the bridge itself.
        prepared.webView.navigationDelegate = nil
        let probe = installProbe(on: prepared)

        load(prepared)

        try await waitForPage(probe, toReport: "main")
        let ready = await waitUntil(within: 5) { host.revealCount > 0 }
        XCTAssertTrue(ready, "the bundle's own main frame reaches the bridge")
        let frameRan = await waitUntil(within: generousTimeout) { probe.reports.contains("frame") }
        XCTAssertTrue(frameRan, "the iframe ran, so it did call the bridge")
        // Its bridge call was posted right after; give it the hop the main
        // frame's took.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(host.dismissReasons.count, 0, "an iframe must not reach the bridge")
    }

    // MARK: - Load failures

    func test_bundleThatFailsToLoad_closesThePresentation() async throws {
        let (prepared, host, harness) = try await prepare(html: "<html><body></body></html>")
        defer { harness.cleanup() }
        try FileManager.default.removeItem(at: prepared.bundleURL)

        load(prepared)

        let closed = await waitUntil(within: generousTimeout) { !host.dismissReasons.isEmpty }
        XCTAssertTrue(closed, "a page that can't load must close the sheet, not leave it blank")
    }

    func test_webContentProcessTermination_closesThePresentation() async throws {
        let (prepared, host, harness) = try await prepare(html: "<html><body></body></html>")
        defer { harness.cleanup() }

        prepared.webView.navigationDelegate?.webViewWebContentProcessDidTerminate?(prepared.webView)

        XCTAssertEqual(host.dismissReasons.count, 1, "a dead page must close the sheet, not leave it blank")
    }

    func test_cancelledNavigation_doesNotCloseThePresentation() async throws {
        let (prepared, host, harness) = try await prepare(html: "<html><body></body></html>")
        defer { harness.cleanup() }

        // A newer navigation, or teardown's `stopLoading()`, cancels the
        // one in flight — the page is fine.
        prepared.webView.navigationDelegate?.webView?(
            prepared.webView, didFailProvisionalNavigation: nil, withError: URLError(.cancelled)
        )

        XCTAssertEqual(host.dismissReasons.count, 0)
    }

    // MARK: - Decisions

    func test_onlyTheBundleFile_isTheBundlePage() {
        let bundle = URL(fileURLWithPath: "/tmp/galva/1.0.0.html")
        func isBundlePage(_ string: String?) -> Bool {
            InAppMessageNavigationPolicy.isBundlePage(string.flatMap(URL.init(string:)), bundleURL: bundle)
        }
        XCTAssertTrue(isBundlePage("file:///tmp/galva/1.0.0.html"))
        XCTAssertTrue(isBundlePage("file:///tmp/galva/1.0.0.html#offer"))
        XCTAssertFalse(isBundlePage("file:///tmp/galva/other.html"))
        XCTAssertFalse(isBundlePage("https://evil.example/tmp/galva/1.0.0.html"))
        XCTAssertFalse(isBundlePage("about:blank"))
        XCTAssertFalse(isBundlePage("about:srcdoc"))
        XCTAssertFalse(isBundlePage(nil))
    }

    func test_bridge_acceptsOnlyAFileMainFrame() {
        XCTAssertTrue(NativeBridge.acceptsMessage(fromMainFrame: true, originProtocol: "file"))
        XCTAssertFalse(NativeBridge.acceptsMessage(fromMainFrame: false, originProtocol: "file"), "an iframe")
        XCTAssertFalse(NativeBridge.acceptsMessage(fromMainFrame: true, originProtocol: "https"), "a remote page")
        XCTAssertFalse(NativeBridge.acceptsMessage(fromMainFrame: false, originProtocol: "https"))
    }

    func test_onlyACancelledNavigation_isNotFatal() {
        XCTAssertFalse(InAppMessageNavigationPolicy.isFatal(URLError(.cancelled)))
        XCTAssertTrue(InAppMessageNavigationPolicy.isFatal(URLError(.fileDoesNotExist)))
        XCTAssertTrue(InAppMessageNavigationPolicy.isFatal(NSError(domain: "WebKitErrorDomain", code: 102)))
    }

    // MARK: - Helpers

    /// Prepare a message whose bundle is `html`, the way the SwiftUI sheet
    /// does, with `host` as its presentation.
    private func prepare(html: String) async throws -> (PreparedInAppMessage, RecordingHost, SDKHarness) {
        URLProtocolStub.reset()
        URLProtocolStub.handler = InAppMessageStubServer.handler(html: html)
        let harness = await SDKHarness.makeConfigured()
        _ = await harness.installInAppMessaging()
        let host = RecordingHost()
        let prepared = try await harness.core.prepareInAppMessage(makeInAppMessage(), host: host)
        host.webView = prepared.webView
        return (prepared, host, harness)
    }

    /// Load the bundle, as the SwiftUI sheet does once it appears: on screen,
    /// in a key window. In a test runner that isn't a foreground app, WebKit
    /// may never run a page whose view isn't in a window.
    private func load(_ prepared: PreparedInAppMessage) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        prepared.webView.frame = root.view.bounds
        root.view.addSubview(prepared.webView)
        window.makeKeyAndVisible()
        windows.append(window)
        prepared.webView.loadFileURL(
            prepared.bundleURL,
            allowingReadAccessTo: prepared.bundleURL.deletingLastPathComponent()
        )
    }

    /// A `probe` script message handler on the page, outside the bridge, so
    /// a test knows which frames ran. Removed at the end of the test.
    private func installProbe(on prepared: PreparedInAppMessage) -> ScriptProbe {
        let probe = ScriptProbe()
        let controller = prepared.webView.configuration.userContentController
        controller.add(probe, name: "probe")
        addTeardownBlock { @MainActor in controller.removeScriptMessageHandler(forName: "probe") }
        return probe
    }

    /// Wait for the page to tell `probe` it ran. Skips the test when WebKit
    /// never runs it: what the test checks never happened, and the bridge's
    /// decisions are covered by the pure tests below and the E2E suite.
    private func waitForPage(_ probe: ScriptProbe, toReport name: String) async throws {
        guard await waitUntil(within: generousTimeout, { probe.reports.contains(name) }) else {
            throw XCTSkip("WebKit never ran the test page in this test runner")
        }
    }

    /// A page that calls bridge method `name` as soon as it runs.
    private static func page(posting name: String) -> String {
        """
        <html><body><script>
        window.webkit.messageHandlers.galva.postMessage({name: '\(name)', requestId: 'r', payload: {}});
        </script></body></html>
        """
    }
}

/// Records what a page posts to the `probe` script message handler.
@MainActor
private final class ScriptProbe: NSObject, WKScriptMessageHandler {
    private(set) var reports: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let report = message.body as? String { reports.append(report) }
    }
}

#endif
