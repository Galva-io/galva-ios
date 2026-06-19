//
//  IdentityEventUITests.swift
//  GalvaDemoUITests
//
//  Verifies the identify/track pipeline actually leaves the SDK: the mock
//  records every `/identities/batchCollect` body, the control panel surfaces
//  the latest one, and these tests assert the expected user id + event name
//  appear in it. The mock's `flushSize: 1` makes each event flush immediately.
//

import XCTest

final class IdentityEventUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_identify_uploadsEndUserId() {
        let app = launchApp(scenario: .noMessages)
        tapControl(app, "identify")

        let debug = app.staticTexts["uploadDebug"]
        XCTAssertTrue(debug.waitForExistence(timeout: 10))
        expectLabel(debug, contains: "user_42")
    }

    func test_track_uploadsEventName() {
        let app = launchApp(scenario: .noMessages)
        tapControl(app, "track")

        let debug = app.staticTexts["uploadDebug"]
        XCTAssertTrue(debug.waitForExistence(timeout: 10))
        expectLabel(debug, contains: "E2EButtonTapped")
    }
}
