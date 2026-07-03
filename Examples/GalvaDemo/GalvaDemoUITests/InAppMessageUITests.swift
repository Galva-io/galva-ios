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

    func test_deepLinkRace_fetchSuppressed_untilNextReturnEvent() {
        // THE regression guard for the email-deep-link double-present, under the
        // one-message-per-stint budget. The mock serves the deep link's resolve
        // with ~2s of latency (deepLinkRace), so tapping "Next message" right
        // after the deep link lands the poll squarely INSIDE the deep-link
        // flight — the exact real-world interleaving. Contract:
        //   1. the deep link D presents ALONE (the poll's fetch is suppressed
        //      while D's claim is pending),
        //   2. the polled message P does NOT show after D closes either — the
        //      stint's budget is spent,
        //   3. P surfaces on the NEXT RETURN EVENT (background → foreground).
        // Broken code presents P mid-flight and collides with D (fails 1).
        let app = launchApp(scenario: .deepLinkRace)
        tapControl(app, "identify") // openCommunication links defer until identified

        // Deep link D (22222222…) starts its ~2s flight and claims the slot.
        tapControl(app, "openDeepLink")
        // Poll triggered mid-flight — the fetch must be suppressed entirely.
        tapControl(app, "nextMessage")

        // 1. D presents alone, serving its OWN payload.
        let deepLinkMsg = app.webViews.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "msgid:22222222")
        ).firstMatch
        XCTAssertTrue(deepLinkMsg.waitForExistence(timeout: 25),
                      "the deep-link message must present after its delayed resolve")
        let polledMsg = app.webViews.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "msgid:44444444")
        ).firstMatch
        XCTAssertFalse(polledMsg.exists,
                       "the mid-flight poll must be suppressed — no second message")

        // 2. Close D — P must STILL not show (budget spent; dismissal is not a
        //    return event).
        let close = app.webViews.buttons["Close E2E"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10))
        XCTAssertFalse(polledMsg.waitForExistence(timeout: 4),
                       "no further message this stint — the budget is spent")

        // 3. Background → foreground: a return event starts a fresh stint, the
        //    poll runs again, and the suppressed message finally surfaces.
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(polledMsg.waitForExistence(timeout: 25),
                      "the suppressed message must surface on the next return event")
    }

    func test_deepLink_and_pollMessage_doNotCollide() {
        // A poll triggered while a deep-link message is ON SCREEN must be
        // suppressed by the display budget (the slot is `.used` and the sheet is
        // active, so the fetch is skipped entirely). The deep-link sheet stays
        // presented, serving its OWN message id (per-message bridge scoping).
        // The mid-flight variant — poll landing DURING the deep-link resolve —
        // is covered deterministically by `test_deepLinkRace_…`.
        let app = launchApp(scenario: .deepLinkTarget)

        // openCommunication deep links are deferred until identify — identify
        // first so the link renders immediately.
        tapControl(app, "identify")
        // Deep link presents communicationId 22222222-… via the UIKit presenter.
        tapControl(app, "openDeepLink")
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 20),
                      "deep-link message should present")
        let deepLinkMsg = app.webViews.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "msgid:22222222")
        ).firstMatch
        XCTAssertTrue(deepLinkMsg.waitForExistence(timeout: 15),
                      "the deep-link WebView must serve its OWN message id (Fix A)")

        // A concurrent poll now delivers a DIFFERENT message (44444444-…). The
        // SwiftUI auto-display must yield to the active deep-link (Fix B).
        tapControl(app, "nextMessage")
        let pollMsg = app.webViews.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "msgid:44444444")
        ).firstMatch
        XCTAssertFalse(pollMsg.waitForExistence(timeout: 6),
                       "a polled message must not stack on / replace the active deep-link")
        XCTAssertTrue(deepLinkMsg.exists,
                      "the deep-link message must remain presented, serving its own id")
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
