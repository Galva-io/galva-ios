//
//  DeepLinkUITests.swift
//  GalvaDemoUITests
//
//  End-to-end coverage of `gvdemo://openCommunication?communicationId=…`:
//  it renders for an identified user, and — the headline behavior — it is
//  DEFERRED while anonymous and replays automatically on identify.
//
//  The `deepLinkTarget` scenario returns an empty poll, so nothing renders
//  except as a direct result of the deep link (no auto-display interference).
//

import XCTest

final class DeepLinkUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_deepLink_isDeferredUntilIdentify() {
        let app = launchApp(scenario: .deepLinkTarget)

        // Anonymous: opening the deep link must NOT render — it's held until
        // the SDK knows who the user is.
        tapControl(app, "openDeepLink")
        XCTAssertFalse(
            app.webViews.firstMatch.waitForExistence(timeout: 4),
            "an openCommunication deep link must not render while anonymous"
        )

        // Identify → the deferred link replays and renders.
        tapControl(app, "identify")
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 20),
            "the deferred deep link should render after identify()"
        )
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 10))
    }

    func test_deepLink_rendersWhenAlreadyIdentified() {
        let app = launchApp(scenario: .deepLinkTarget)

        tapControl(app, "identify")
        tapControl(app, "openDeepLink")
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 20),
            "an openCommunication deep link should render immediately when identified"
        )
        XCTAssertTrue(app.webViews.staticTexts["E2E Offer"].waitForExistence(timeout: 10))
    }
}
