//
//  E2ESupport.swift
//  GalvaDemoUITests
//
//  Shared launch + assertion helpers for the end-to-end UI tests.
//

import XCTest

/// Mirrors `E2EScenario` in the app target — selects which canned backend the
/// in-process mock serves for a launch.
enum E2EScenarioArg: String {
    case showInAppMessage
    case deepLinkTarget
    case noMessages
}

extension XCTestCase {

    /// Launch the demo app in E2E mode with the in-process mock + given scenario.
    func launchApp(scenario: E2EScenarioArg) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GALVA_E2E"] = "1"
        app.launchEnvironment["GALVA_E2E_SCENARIO"] = scenario.rawValue
        app.launch()
        return app
    }

    /// Wait for a control-panel button by accessibility id, then tap it.
    func tapControl(
        _ app: XCUIApplication,
        _ identifier: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons[identifier]
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "control button '\(identifier)' never appeared",
            file: file, line: line
        )
        button.tap()
    }

    /// Wait until `element`'s accessibility label contains `substring`.
    func expectLabel(
        _ element: XCUIElement,
        contains substring: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "label CONTAINS %@", substring)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result, .completed,
            "expected '\(substring)' in element label; was '\(element.label)'",
            file: file, line: line
        )
    }
}
