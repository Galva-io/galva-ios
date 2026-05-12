//
//  CommunicationEndpointTests.swift
//  GalvaTests
//
//  Covers the internal wire-format model + the public→wire bridges that
//  let `Communication.registerPushToken(_:platform:)` and friends accept
//  public enums without leaking the internal wire spelling.
//
//  Two concerns:
//    1. Codable shape — email vs push-notification discriminator, kebab-
//       case channelType values, in-app rejected for endpoint payloads.
//    2. Bridges — `Communication.PushPlatform.wireValue` and
//       `Communication.Channel.wireValue` round-trip correctly.
//

import Foundation
@testable import Galva
import XCTest

final class CommunicationEndpointCodableTests: XCTestCase {

    // MARK: - Encode

    func test_email_encodesToFlatShape() throws {
        let endpoint = CommunicationEndpoint.email("a@b.co")
        let dict = try encodeAsDictionary(endpoint)
        XCTAssertEqual(dict["channelType"] as? String, "email")
        XCTAssertEqual(dict["email"] as? String, "a@b.co")
        XCTAssertNil(dict["platform"], "Email endpoint must not include 'platform'")
        XCTAssertNil(dict["token"], "Email endpoint must not include 'token'")
    }

    func test_pushApns_encodesToFlatShape() throws {
        let endpoint = CommunicationEndpoint.pushNotification(platform: .apns, token: "TOK")
        let dict = try encodeAsDictionary(endpoint)
        XCTAssertEqual(dict["channelType"] as? String, "push-notification",
                       "channelType must use kebab-case 'push-notification'")
        XCTAssertEqual(dict["platform"] as? String, "apns")
        XCTAssertEqual(dict["token"] as? String, "TOK")
        XCTAssertNil(dict["email"], "Push endpoint must not include 'email'")
    }

    func test_pushFcm_encodesPlatformAsFcm() throws {
        let endpoint = CommunicationEndpoint.pushNotification(platform: .fcm, token: "T")
        let dict = try encodeAsDictionary(endpoint)
        XCTAssertEqual(dict["platform"] as? String, "fcm")
    }

    // MARK: - Decode

    func test_decode_email() throws {
        let json = Data(#"{"channelType":"email","email":"x@y.com"}"#.utf8)
        let endpoint = try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        XCTAssertEqual(endpoint, .email("x@y.com"))
    }

    func test_decode_pushApns() throws {
        let json = Data(#"""
        {"channelType":"push-notification","platform":"apns","token":"abc"}
        """#.utf8)
        let endpoint = try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        XCTAssertEqual(endpoint, .pushNotification(platform: .apns, token: "abc"))
    }

    func test_decode_inAppChannel_isRejected() {
        // "in-app" is a valid channelType for SET-PREFERENCE messages, but
        // there's no in-app *endpoint* — only email and push. The decoder
        // must reject it.
        let json = Data(#"{"channelType":"in-app"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        )
    }

    func test_decode_unknownChannel_isRejected() {
        let json = Data(#"{"channelType":"sms","number":"+123"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        )
    }

    func test_decode_pushWithoutPlatform_isRejected() {
        let json = Data(#"{"channelType":"push-notification","token":"abc"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        )
    }

    func test_decode_pushWithoutToken_isRejected() {
        let json = Data(#"{"channelType":"push-notification","platform":"apns"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        )
    }

    // MARK: - Round-trip

    func test_email_roundTrip() throws {
        try assertRoundTrip(.email("user@example.com"))
    }

    func test_pushApns_roundTrip() throws {
        try assertRoundTrip(.pushNotification(platform: .apns, token: "TOK"))
    }

    func test_pushFcm_roundTrip() throws {
        try assertRoundTrip(.pushNotification(platform: .fcm, token: "TOK"))
    }

    // MARK: - ChannelType raw values match spec

    func test_channelType_rawValuesMatchSpec() {
        XCTAssertEqual(CommunicationEndpoint.ChannelType.email.rawValue, "email")
        XCTAssertEqual(CommunicationEndpoint.ChannelType.pushNotification.rawValue, "push-notification")
        XCTAssertEqual(CommunicationEndpoint.ChannelType.inApp.rawValue, "in-app")
    }

    // MARK: - Helpers

    private func encodeAsDictionary(_ endpoint: CommunicationEndpoint) throws -> [String: Any] {
        let data = try JSONEncoder().encode(endpoint)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertRoundTrip(
        _ endpoint: CommunicationEndpoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(CommunicationEndpoint.self, from: data)
        XCTAssertEqual(decoded, endpoint, file: file, line: line)
    }
}

// MARK: - Public → wire bridges

final class CommunicationBridgeTests: XCTestCase {

    func test_pushPlatform_bridgesApns() {
        XCTAssertEqual(Communication.PushPlatform.apns.wireValue, .apns)
    }

    func test_pushPlatform_bridgesFcm() {
        XCTAssertEqual(Communication.PushPlatform.fcm.wireValue, .fcm)
    }

    func test_channel_bridgesEmail() {
        XCTAssertEqual(Communication.Channel.email.wireValue, .email)
    }

    func test_channel_bridgesPushNotification() {
        XCTAssertEqual(Communication.Channel.pushNotification.wireValue, .pushNotification)
    }

    func test_channel_bridgesInApp() {
        XCTAssertEqual(Communication.Channel.inApp.wireValue, .inApp)
    }

    func test_allChannelCases_haveExhaustiveBridges() {
        // If a new Communication.Channel case is added, the switch in
        // `wireValue` is the only place that needs updating — this loop
        // would still pass. The real safety net is the switch's
        // exhaustiveness check at compile time. We do, however, assert
        // here that every raw value maps to a non-nil wire enum.
        let allRawValues = ["email", "pushNotification", "inApp"]
        for raw in allRawValues {
            XCTAssertNotNil(Communication.Channel(rawValue: raw),
                            "Missing raw mapping for \(raw)")
        }
    }
}
