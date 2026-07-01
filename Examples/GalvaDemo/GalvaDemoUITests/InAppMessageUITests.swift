//
//  InAppMessageUITests.swift
//  GalvaDemoUITests
//
//  End-to-end coverage of the in-app message stack against the in-process
//  mock: poll → resolve → bundle download → WebView present → native bridge.
//  Tapping "Check for messages" forces the poll (cold-start activation can
//  race the SDK's lifecycle subscription), then auto-display renders the sheet.
//

import XCTest

final class InAppMessageUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_autoDisplaysMessage_andRendersResolvedPayload() {
        let app = launchApp(scenario: .showInAppMessage)
        tapControl(app, "checkMessages")

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 20),
                      "the in-app message WebView should be presented")
        // The bundle overwrites its title with the resolved payload's `title`
        // via getMessageData — proves the bridge round-trip + render.
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 10),
                      "resolved payload title should render in the bundle")
    }

    func test_pageContext_injectsNonZeroSafeArea() {
        // The WebView must receive the presented sheet's real safe area (notch /
        // home-indicator insets), not `.zero`. On a notched simulator the bundle
        // surfaces a `safeArea:nonzero…` marker (top>0 OR bottom>0) once
        // getPageContext resolves. This exercises the SwiftUI auto-display path.
        // Requires a notched device — CI pins iPhone 16 Pro.
        assertNonZeroSafeArea(scenario: .showInAppMessage)
    }

    func test_pageContext_injectsNonZeroSafeArea_uikitPresenter() {
        // The UIKit `show(in:)` presenter (the path the React Native wrapper
        // drives through `showMessage`) previously loaded the bundle in
        // viewDidLoad, so getPageContext() could run before the sheet was laid
        // out and read a `.zero` safe area. The VC now defers the load to
        // viewDidAppear; assert the WebView receives non-zero insets.
        assertNonZeroSafeArea(scenario: .showInAppMessageUIKit)
    }

    func test_pageContext_injectsNonZeroSafeArea_cachedSecondPresentation() {
        // The real-world failure was the SECOND, cached presentation reading a
        // `.zero` safe area (the first, cache-miss present was correct). This
        // reproduces the exact SCENARIO: message A downloads + caches bundle
        // 1.0.0, is dismissed, then a distinct message B reuses the cached bundle
        // and boots instantly — and B's bundle reads getPageContext() as early as
        // possible (see TestBundle.html). It asserts B still gets non-zero insets.
        //
        // NOTE: this is a positive scenario check, not a fail-without-fix guard.
        // The hermetic in-process harness can't reproduce the *timing* race:
        // WebKit's boot + IPC latency consistently exceeds the SwiftUI mount /
        // window-attachment latency here, so the read always lands after the
        // WebView is in its window (verified — it passes with the off-screen load
        // too). The real-world `.zero` needs environmental timing (main-thread
        // contention, a heavy host view delaying the mount, a warm WebKit
        // process). The fix is correct by construction: the bundle only loads
        // once the view is on screen (viewDidAppear / onAppear).
        let app = launchApp(scenario: .showInAppMessageTwice)

        // First message: present + fully render (caches bundle 1.0.0), dismiss.
        tapControl(app, "checkMessages")
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 20),
                      "first message should render (and cache its bundle)")
        let close = app.webViews.buttons["Close E2E"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10),
                      "first message should dismiss before presenting the second")

        // Second message: distinct id, cached bundle → instant boot (the race).
        tapControl(app, "nextMessage")
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 20),
                      "second (cached) message should render")
        let nonZero = app.webViews.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "safeArea:nonzero")
        ).firstMatch
        XCTAssertTrue(nonZero.waitForExistence(timeout: 10),
                      "the cached second presentation must still inject a non-zero safeArea — "
                      + "a zero here is the real-world race the fix targets")
    }

    /// Present the message via `scenario`, then assert getPageContext() injected
    /// a non-zero safe area into the WebView.
    private func assertNonZeroSafeArea(
        scenario: E2EScenarioArg,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = launchApp(scenario: scenario)
        tapControl(app, "checkMessages")

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20),
                      "the in-app message WebView should be presented",
                      file: file, line: line)
        // Wait for the resolved title first — proves the bundle booted and its
        // getPageContext round-trip completed before we read the safe area.
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 20),
                      "resolved payload title should render before reading safeArea",
                      file: file, line: line)

        let nonZero = app.webViews.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "safeArea:nonzero")
        ).firstMatch
        XCTAssertTrue(nonZero.waitForExistence(timeout: 10),
                      "getPageContext must inject a non-zero safeArea (top/bottom) — "
                      + "a zero inset means the bundle booted before the sheet was laid out",
                      file: file, line: line)
    }

    func test_bridgeApiFetch_roundTrips() {
        let app = launchApp(scenario: .showInAppMessage)
        tapControl(app, "checkMessages")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))

        app.webViews.buttons["Run apiFetch"].tap()
        XCTAssertTrue(app.webViews.staticTexts["apiFetch ok"].waitForExistence(timeout: 10),
                      "apiFetch should proxy through the SDK and resolve ok")
    }

    func test_bridgeShowAlert_presentsNativeAlertAndResolves() {
        let app = launchApp(scenario: .showInAppMessage)
        tapControl(app, "checkMessages")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20))

        app.webViews.buttons["Run showAlert"].tap()
        let okButton = app.alerts["E2E Alert"].buttons["OK"]
        XCTAssertTrue(okButton.waitForExistence(timeout: 10),
                      "native UIAlertController should be presented")
        okButton.tap()
        XCTAssertTrue(app.webViews.staticTexts["alert ok"].waitForExistence(timeout: 10),
                      "showAlert should resolve with the tapped action id")
    }

    func test_dismiss_closesMessage() {
        let app = launchApp(scenario: .showInAppMessage)
        tapControl(app, "checkMessages")

        // Wait for the resolved title to render — not just for the close
        // button to enter the a11y tree. The button appears the instant the
        // WebView is revealed on `ready()`, but on a slow/contended runner
        // that can precede the WebView becoming reliably hit-testable, so a
        // tap fired then never triggers the bundle's `onclick`. The title
        // ("E2E Offer") only renders after a full getMessageData bridge
        // round-trip, which proves the WebView is booted and interactive.
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 20),
                      "bundle should render the resolved payload before we dismiss it")

        let closeButton = app.webViews.buttons["Close E2E"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
        closeButton.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10),
                      "dismiss() should tear down the WebView sheet")
    }
}
