//
//  CommunicationEndpointTests.swift
//  GalvaTests
//
//  Covers the internal `CommunicationEndpoint` wire-format model: the
//  push-notification Codable shape, its kebab-case channelType value, and
//  rejection of unknown or incomplete payloads.
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

    func test_pushApns_encodesToFlatShape() throws {
        let endpoint = CommunicationEndpoint.pushNotification(platform: .apns, token: "TOK")
        let dict = try encodeAsDictionary(endpoint)
        XCTAssertEqual(dict["channelType"] as? String, "push-notification",
                       "channelType must use kebab-case 'push-notification'")
        XCTAssertEqual(dict["platform"] as? String, "apns")
        XCTAssertEqual(dict["token"] as? String, "TOK")
    }

    // MARK: - Decode

    func test_decode_pushApns() throws {
        let json = Data(#"""
        {"channelType":"push-notification","platform":"apns","token":"abc"}
        """#.utf8)
        let endpoint = try JSONDecoder().decode(CommunicationEndpoint.self, from: json)
        XCTAssertEqual(endpoint, .pushNotification(platform: .apns, token: "abc"))
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

    func test_pushApns_roundTrip() throws {
        try assertRoundTrip(.pushNotification(platform: .apns, token: "TOK"))
    }

    // MARK: - ChannelType raw value matches spec

    func test_channelType_rawValuesMatchSpec() {
        XCTAssertEqual(CommunicationEndpoint.ChannelType.pushNotification.rawValue, "push-notification")
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
