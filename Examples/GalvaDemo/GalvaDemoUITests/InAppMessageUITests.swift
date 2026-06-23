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
