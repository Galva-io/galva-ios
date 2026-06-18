//
//  CommunicationEndpointTests.swift
//  GalvaTests
//
//  Covers the internal `CommunicationEndpoint` wire-format model:
//  Codable shape — email vs push-notification discriminator, kebab-case
//  channelType values, in-app rejected for endpoint payloads.
//
//  (The public `Communication` namespace and its public→wire enum bridges
//  were removed: push endpoints are registered automatically from the device
//  token, and email is set via `AppUser.set(.email, …)`.)
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
