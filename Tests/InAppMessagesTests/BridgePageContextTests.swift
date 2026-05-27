//
//  BridgePageContextTests.swift
//  GalvaTests
//
//  Pins the wire shape of the page-context object the bundle reads back
//  from `galva.getPageContext()`. The bundle's TypeScript expects these
//  keys verbatim — any rename here must coordinate with a bridge
//  protocol version bump.
//

import Foundation
@testable import Galva
import XCTest

#if canImport(WebKit)

final class BridgePageContextTests: XCTestCase {

    func test_pageContext_encodesStorefrontCountryCode() throws {
        let context = BridgePageContext(
            messageId: "msg-1",
            sessionToken: "tok",
            bridgeProtocol: "1.0",
            sdkVersion: "1.0.0",
            platform: "ios",
            appVersion: "2.3.4",
            appBuild: "1234",
            pushAuthorization: .authorized,
            locale: "en_US",
            appColorScheme: .dark,
            safeArea: .init(top: 47, bottom: 34, left: 0, right: 0),
            storefrontCountryCode: "USA"
        )
        let data = try JSONEncoder().encode(context)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["storefrontCountryCode"] as? String, "USA")
    }

    func test_pageContext_storefrontCountryCodeOmittedWhenNil() throws {
        // When StoreKit can't resolve the storefront (Simulator without
        // a config, user not signed in), we emit nil. JSONEncoder drops
        // optional nils by default — bundles must `typeof === 'string'`
        // before reading, which is the standard JS-safe pattern.
        let context = BridgePageContext(
            messageId: "msg-1",
            sessionToken: nil,
            bridgeProtocol: "1.0",
            sdkVersion: "1.0.0",
            platform: "ios",
            appVersion: nil,
            appBuild: nil,
            pushAuthorization: nil,
            locale: "en_US",
            appColorScheme: nil,
            safeArea: .init(top: 0, bottom: 0, left: 0, right: 0),
            storefrontCountryCode: nil
        )
        let data = try JSONEncoder().encode(context)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(json["storefrontCountryCode"])
    }

    func test_pageContext_roundTrips() throws {
        let original = BridgePageContext(
            messageId: "msg-1",
            sessionToken: "tok",
            bridgeProtocol: "1.0",
            sdkVersion: "1.0.0",
            platform: "ios",
            appVersion: "2.3.4",
            appBuild: "1234",
            pushAuthorization: .denied,
            locale: "ja_JP",
            appColorScheme: .light,
            safeArea: .init(top: 47, bottom: 34, left: 0, right: 0),
            storefrontCountryCode: "JPN"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BridgePageContext.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

#endif // canImport(WebKit)
