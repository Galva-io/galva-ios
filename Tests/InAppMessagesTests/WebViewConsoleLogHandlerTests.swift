//
//  WebViewConsoleLogHandlerTests.swift
//  GalvaTests
//
//  Covers the pure marshaling of `WebViewConsoleLogHandler` — the bridge
//  that forwards WebView `console.*` output to the SDK logger when debug
//  logging is on. `WKScriptMessage` has no public initializer, so the
//  delegate method itself isn't unit-tested; the level mapping and body
//  parsing (the logic that actually matters) are pure + tested here.
//

import Foundation
@testable import Galva
import XCTest

#if canImport(WebKit)

final class WebViewConsoleLogHandlerTests: XCTestCase {

    // MARK: - mapLevel

    func test_mapLevel_mapsJSConsoleLevels() {
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel("error"), .error)
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel("warn"), .warning)
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel("info"), .info)
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel("debug"), .debug)
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel("log"), .debug)
    }

    func test_mapLevel_unknownDefaultsToDebug() {
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel("trace"), .debug)
        XCTAssertEqual(WebViewConsoleLogHandler.mapLevel(""), .debug)
    }

    // MARK: - parse

    func test_parse_dictBody() {
        let parsed = WebViewConsoleLogHandler.parse(["level": "error", "message": "boom"])
        XCTAssertEqual(parsed.level, "error")
        XCTAssertEqual(parsed.text, "boom")
    }

    func test_parse_dictBody_missingKeysDefault() {
        let parsed = WebViewConsoleLogHandler.parse([String: Any]())
        XCTAssertEqual(parsed.level, "log")
        XCTAssertEqual(parsed.text, "")
    }

    func test_parse_bareStringBody() {
        let parsed = WebViewConsoleLogHandler.parse("just a string")
        XCTAssertEqual(parsed.level, "log")
        XCTAssertEqual(parsed.text, "just a string")
    }

    func test_parse_unexpectedBody_stringifies() {
        let parsed = WebViewConsoleLogHandler.parse(42)
        XCTAssertEqual(parsed.level, "log")
        XCTAssertEqual(parsed.text, "42")
    }
}

#endif // canImport(WebKit)
