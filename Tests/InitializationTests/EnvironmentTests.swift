//
//  EnvironmentTests.swift
//  GalvaTests
//
//  Verifies that `Galva.Environment` maps each case to the correct API +
//  WebView bundle CDN URL. Production accidentally pointing at galva.dev
//  (or vice versa) would be a silent data-corruption bug, so we lock the
//  mapping behind explicit assertions.
//

import Foundation
@testable import Galva
import XCTest

final class EnvironmentTests: XCTestCase {

    func test_production_pointsAtDotIo() {
        XCTAssertEqual(
            Galva.Environment.production.apiBaseURL.absoluteString,
            "https://api.galva.io"
        )
        XCTAssertEqual(
            Galva.Environment.production.webviewBundleCDN.absoluteString,
            "https://webview.galva.io"
        )
    }

    func test_development_pointsAtDotDev() {
        XCTAssertEqual(
            Galva.Environment.development.apiBaseURL.absoluteString,
            "https://api.galva.dev"
        )
        XCTAssertEqual(
            Galva.Environment.development.webviewBundleCDN.absoluteString,
            "https://webview.galva.dev"
        )
    }

    func test_custom_usesSuppliedURLs() {
        let api = URL(string: "https://galva.internal.example.com")!
        let cdn = URL(string: "https://cdn.internal.example.com")!
        let env: Galva.Environment = .custom(apiBaseURL: api, webviewBundleCDN: cdn)
        XCTAssertEqual(env.apiBaseURL, api)
        XCTAssertEqual(env.webviewBundleCDN, cdn)
    }

    // MARK: - SDKConstants endpoint builders

    func test_communicationResolvePath_buildsExpectedString() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000abc")!
        XCTAssertEqual(
            SDKConstants.communicationResolvePath(messageId: id),
            "/identities/communications/00000000-0000-0000-0000-000000000ABC/resolve"
        )
    }

    func test_webviewBundleURL_combinesCDNAndVersion() {
        let cdn = URL(string: "https://webview.galva.dev")!
        let url = SDKConstants.webviewBundleURL(version: "1.2.3", cdn: cdn)
        XCTAssertEqual(url.absoluteString, "https://webview.galva.dev/1.2.3.html")
    }
}
