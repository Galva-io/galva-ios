//
//  MessageWireFormatTests.swift
//  GalvaTests
//
//  Covers the OpenAPI-aligned wire shape for every Message variant. Each
//  test encodes a representative Message, decodes the bytes as raw
//  JSON, and asserts:
//
//    • The flat shape — every body field lives at the root, no nested
//      `body` envelope (matches the OpenAPI `anyOf` discriminator).
//    • The `type` discriminator value matches the spec exactly
//      (`"create-communication-endpoint"` not `"createCommunicationEndpoint"`).
//    • Required fields are present.
//    • Optional/nil fields are omitted from the wire.
//    • The Message round-trips losslessly back through the decoder.
//
//  Asserting against `JSONSerialization` output (not raw strings) lets us
//  ignore key ordering and whitespace.
//

import Foundation
@testable import Galva
import XCTest

final class MessageWireFormatTests: XCTestCase {

    // MARK: - identify

    func test_identify_wireShape() throws {
        let traits: [String: AnyJSONValue] = [
            "$gv_email": .string("a@b.co"),
            "$gv_country": .string("US"),
        ]
        let msg = Message(
            messageId: UUID(uuidString: "01890000-0000-7000-8000-000000000001")!,
            anonymousId: "anon_1",
            endUserId: "user_1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            context: nil,
            body: .identify(traits: traits)
        )

        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "identify")
        XCTAssertEqual(dict["anonymousId"] as? String, "anon_1")
        XCTAssertEqual(dict["endUserId"] as? String, "user_1")
        XCTAssertNotNil(dict["timestamp"] as? String, "timestamp must be ISO 8601 string")
        XCTAssertNotNil(dict["messageId"] as? String)

        let onTheWireTraits = try XCTUnwrap(dict["traits"] as? [String: Any])
        XCTAssertEqual(onTheWireTraits["$gv_email"] as? String, "a@b.co")
        XCTAssertEqual(onTheWireTraits["$gv_country"] as? String, "US")

        try assertRoundTripsToEqual(msg)
    }

    func test_identify_nilTraitsAreOmitted() throws {
        let msg = Message(
            anonymousId: "anon",
            endUserId: nil,
            context: nil,
            body: .identify(traits: nil)
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertNil(dict["traits"], "nil traits must not appear on the wire")
        XCTAssertNil(dict["endUserId"], "nil endUserId must not appear on the wire")
        try assertRoundTripsToEqual(msg)
    }

    // MARK: - alias

    func test_alias_wireShape() throws {
        let msg = Message(
            anonymousId: "anon_prev",
            endUserId: "user_target",
            context: nil,
            body: .alias(previousId: "anon_prev", targetId: "user_target")
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "alias")
        XCTAssertEqual(dict["previousId"] as? String, "anon_prev")
        XCTAssertEqual(dict["targetId"] as? String, "user_target")
        try assertRoundTripsToEqual(msg)
    }

    // MARK: - track

    func test_track_wireShape_withProperties() throws {
        let props: [String: AnyJSONValue] = [
            "sku": .string("pro_yearly"),
            "price": .double(9.99),
        ]
        let msg = Message(
            anonymousId: "anon",
            endUserId: "user",
            context: nil,
            body: .track(event: "Purchase",
                         properties: props,
                         sourceType: .productBilling,
                         sourceId: "src-7")
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "track")
        XCTAssertEqual(dict["event"] as? String, "Purchase")
        XCTAssertEqual(dict["sourceType"] as? String, "product-billing",
                       "sourceType uses kebab-case on the wire")
        XCTAssertEqual(dict["sourceId"] as? String, "src-7")
        let onTheWireProps = try XCTUnwrap(dict["properties"] as? [String: Any])
        XCTAssertEqual(onTheWireProps["sku"] as? String, "pro_yearly")
        XCTAssertEqual(onTheWireProps["price"] as? Double, 9.99)
        try assertRoundTripsToEqual(msg)
    }

    func test_track_withoutOptionalFields() throws {
        let msg = Message(
            anonymousId: "anon",
            endUserId: nil,
            context: nil,
            body: .track(event: "ButtonTapped",
                         properties: nil,
                         sourceType: nil,
                         sourceId: nil)
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["event"] as? String, "ButtonTapped")
        XCTAssertNil(dict["properties"])
        XCTAssertNil(dict["sourceType"])
        XCTAssertNil(dict["sourceId"])
        try assertRoundTripsToEqual(msg)
    }

    func test_track_sourceTypeEnum_encodesAllRawValues() throws {
        let cases: [(Message.Body.TrackSource, String)] = [
            (.profile, "profile"),
            (.product, "product"),
            (.plan, "plan"),
            (.productBilling, "product-billing"),
            (.entitlement, "entitlement"),
        ]
        for (source, raw) in cases {
            let msg = Message(
                anonymousId: "anon",
                endUserId: nil,
                context: nil,
                body: .track(event: "e", properties: nil, sourceType: source, sourceId: nil)
            )
            let dict = try encodeAsDictionary(msg)
            XCTAssertEqual(dict["sourceType"] as? String, raw,
                           "sourceType \(source) should encode as \"\(raw)\"")
        }
    }

    // MARK: - create-communication-endpoint

    func test_createCommunicationEndpoint_email() throws {
        let msg = Message(
            anonymousId: "anon",
            endUserId: "user",
            context: nil,
            body: .createCommunicationEndpoint(.email("a@b.co"))
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "create-communication-endpoint")
        let endpoint = try XCTUnwrap(dict["endpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["channelType"] as? String, "email")
        XCTAssertEqual(endpoint["email"] as? String, "a@b.co")
        try assertRoundTripsToEqual(msg)
    }

    func test_createCommunicationEndpoint_pushApns() throws {
        let msg = Message(
            anonymousId: "anon",
            endUserId: "user",
            context: nil,
            body: .createCommunicationEndpoint(.pushNotification(platform: .apns, token: "TOK"))
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "create-communication-endpoint")
        let endpoint = try XCTUnwrap(dict["endpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["channelType"] as? String, "push-notification")
        XCTAssertEqual(endpoint["platform"] as? String, "apns")
        XCTAssertEqual(endpoint["token"] as? String, "TOK")
        try assertRoundTripsToEqual(msg)
    }

    // MARK: - delete-communication-endpoint

    func test_deleteCommunicationEndpoint_fcm() throws {
        let msg = Message(
            anonymousId: "anon",
            endUserId: "user",
            context: nil,
            body: .deleteCommunicationEndpoint(.pushNotification(platform: .fcm, token: "FCM_TOK"))
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "delete-communication-endpoint")
        let endpoint = try XCTUnwrap(dict["endpoint"] as? [String: Any])
        XCTAssertEqual(endpoint["channelType"] as? String, "push-notification")
        XCTAssertEqual(endpoint["platform"] as? String, "fcm")
        XCTAssertEqual(endpoint["token"] as? String, "FCM_TOK")
        try assertRoundTripsToEqual(msg)
    }

    // MARK: - set-communication-preference

    func test_setCommunicationPreference_wireShape() throws {
        let categories: [String: Bool] = [
            "payment-recovery": false,
            "winback": true,
        ]
        let msg = Message(
            anonymousId: "anon",
            endUserId: "user",
            context: nil,
            body: .setCommunicationPreference(
                channelType: .email,
                disabled: true,
                categories: categories
            )
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["type"] as? String, "set-communication-preference")
        XCTAssertEqual(dict["channelType"] as? String, "email")
        XCTAssertEqual(dict["disabled"] as? Bool, true)
        let onTheWire = try XCTUnwrap(dict["categories"] as? [String: Bool])
        XCTAssertEqual(onTheWire["payment-recovery"], false)
        XCTAssertEqual(onTheWire["winback"], true)
        try assertRoundTripsToEqual(msg)
    }

    func test_setCommunicationPreference_onlyChannelRequired() throws {
        // OpenAPI requires only channelType; disabled and categories are optional.
        let msg = Message(
            anonymousId: "anon",
            endUserId: nil,
            context: nil,
            body: .setCommunicationPreference(
                channelType: .inApp,
                disabled: nil,
                categories: nil
            )
        )
        let dict = try encodeAsDictionary(msg)
        XCTAssertEqual(dict["channelType"] as? String, "in-app")
        XCTAssertNil(dict["disabled"])
        XCTAssertNil(dict["categories"])
        try assertRoundTripsToEqual(msg)
    }

    // MARK: - Batch envelope

    func test_batchCollectRequest_wireShape() throws {
        let msgs = [
            Message(anonymousId: "a", endUserId: nil, context: nil,
                    body: .track(event: "e", properties: nil,
                                 sourceType: nil, sourceId: nil)),
            Message(anonymousId: "a", endUserId: "u", context: nil,
                    body: .identify(traits: nil)),
        ]
        let envelope = BatchCollectRequest(messages: msgs, sentAt: Date())
        let data = try makeEncoder().encode(envelope)
        let dict = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let onTheWireMessages = try XCTUnwrap(dict["messages"] as? [[String: Any]])
        XCTAssertEqual(onTheWireMessages.count, 2)
        XCTAssertEqual(onTheWireMessages[0]["type"] as? String, "track")
        XCTAssertEqual(onTheWireMessages[1]["type"] as? String, "identify")
        XCTAssertNotNil(dict["sentAt"] as? String, "sentAt must be ISO 8601 string")
    }

    // MARK: - Type discriminator decode

    func test_decoder_dispatchesOnTypeDiscriminator() throws {
        // A minimal envelope; we just need to confirm the right `Body` is built.
        let json = #"""
        {
          "messageId": "01890000-0000-7000-8000-000000000002",
          "timestamp": "2026-05-12T10:00:00.000Z",
          "type": "identify",
          "anonymousId": "anon"
        }
        """#
        let decoded = try makeDecoder().decode(Message.self, from: Data(json.utf8))
        guard case .identify(let traits) = decoded.body else {
            return XCTFail("Expected .identify, got \(decoded.body)")
        }
        XCTAssertNil(traits)
        XCTAssertEqual(decoded.anonymousId, "anon")
    }

    func test_decoder_rejectsUnknownDiscriminator() {
        let json = #"""
        { "messageId": "01890000-0000-7000-8000-000000000003",
          "timestamp": "2026-05-12T10:00:00.000Z",
          "type": "something-new"
        }
        """#
        XCTAssertThrowsError(
            try makeDecoder().decode(Message.self, from: Data(json.utf8))
        )
    }

    // MARK: - Helpers

    /// Encode using the same date strategy the production Uploader uses,
    /// then surface as a plain dictionary so key order doesn't matter.
    private func encodeAsDictionary(_ msg: Message) throws -> [String: Any] {
        let data = try makeEncoder().encode(msg)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Expected top-level JSON object"
        )
    }

    private func assertRoundTripsToEqual(
        _ msg: Message,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try makeEncoder().encode(msg)
        let decoded = try makeDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded.messageId, msg.messageId, file: file, line: line)
        XCTAssertEqual(decoded.anonymousId, msg.anonymousId, file: file, line: line)
        XCTAssertEqual(decoded.endUserId, msg.endUserId, file: file, line: line)
        XCTAssertEqual(decoded.body, msg.body, file: file, line: line)
        // Timestamp precision: ISO 8601 with fractional seconds, accept 1ms slop.
        XCTAssertEqual(
            decoded.timestamp.timeIntervalSince1970,
            msg.timestamp.timeIntervalSince1970,
            accuracy: 0.001,
            file: file, line: line
        )
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = ISO8601DateFormatter.galva.date(from: s) { return date }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid ISO 8601 date: \(s)"
            )
        }
        return d
    }
}
