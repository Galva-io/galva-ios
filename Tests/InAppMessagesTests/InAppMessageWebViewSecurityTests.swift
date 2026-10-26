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
//  Runs on the iOS Simulator.
//

import Foundation
@testable import Galva
import XCTest
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class InAppMessageWebViewSecurityTests: XCTestCase {

    override func tearDown() async throws {
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    // MARK: - Navigation

    func test_pageTheBundleNavigatesTo_isBlocked_andGetsNoBridge() async throws {
        // The bundle sends the WebView to another file:// page, which calls
        // the bridge.
        let (prepared, host, harness) = try await prepare(html: """
        <html><body><script>
        setTimeout(function () { location.href = 'other.html'; }, 0);
        </script></body></html>
        """)
        defer { harness.cleanup() }
        let directory = prepared.bundleURL.deletingLastPathComponent()
        try Self.page(posting: "dismiss").write(
            to: directory.appendingPathComponent("other.html"), atomically: true, encoding: .utf8
        )

        load(prepared)

        let left = await waitUntil(within: 1.5) {
            prepared.webView.url?.lastPathComponent == "other.html" || !host.dismissReasons.isEmpty
        }
        XCTAssertFalse(left, "navigation away from the bundle must be blocked")
        XCTAssertEqual(prepared.webView.url?.path, prepared.bundleURL.path)
        XCTAssertEqual(host.dismissReasons.count, 0, "no other page may reach the bridge")
    }

    func test_bridge_ignoresMessagesFromAnIframe() async throws {
        // The iframe calls `dismiss`; the main frame calls `ready` once the
        // iframe has loaded.
        let (prepared, host, harness) = try await prepare(html: """
        <html><body>
        <iframe srcdoc="<script>window.webkit.messageHandlers.galva.postMessage({name: 'dismiss', requestId: 'frame', payload: {}})</script>"></iframe>
        <script>
        window.onload = function () {
          window.webkit.messageHandlers.galva.postMessage({name: 'ready', requestId: 'main', payload: {}});
        };
        </script>
        </body></html>
        """)
        defer { harness.cleanup() }
        // Let the iframe load, so this checks the bridge itself.
        prepared.webView.navigationDelegate = nil

        load(prepared)

        let ready = await waitUntil(within: generousTimeout) { host.revealCount > 0 }
        XCTAssertTrue(ready, "the bundle's own main frame reaches the bridge")
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

    /// Load the bundle, as the SwiftUI sheet does once it appears.
    private func load(_ prepared: PreparedInAppMessage) {
        prepared.webView.loadFileURL(
            prepared.bundleURL,
            allowingReadAccessTo: prepared.bundleURL.deletingLastPathComponent()
        )
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

#endif
