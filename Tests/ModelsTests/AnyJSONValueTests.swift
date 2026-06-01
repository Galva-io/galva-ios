//
//  AnyJSONValueTests.swift
//  GalvaTests
//
//  Covers the type-erased JSON wrapper used for the wire `traits`,
//  `properties`, and `categories` maps. Two concerns:
//
//    1. Lossless Codable round-trip for every variant (null/bool/int/
//       double/string/array/object), including deep nesting.
//    2. Coercion from every `GalvaCompatibleValue` Swift type the SDK
//       documents as accepted.
//

import Foundation
@testable import Galva
import XCTest

final class AnyJSONValueCodableTests: XCTestCase {

    // MARK: - Single-variant round trips

    func test_null_roundTrips() throws {
        try assertRoundTrip(.null, decodesAs: .null)
    }

    func test_bool_roundTrips() throws {
        try assertRoundTrip(.bool(true), decodesAs: .bool(true))
        try assertRoundTrip(.bool(false), decodesAs: .bool(false))
    }

    func test_int_roundTrips() throws {
        try assertRoundTrip(.int(0), decodesAs: .int(0))
        try assertRoundTrip(.int(42), decodesAs: .int(42))
        try assertRoundTrip(.int(-1), decodesAs: .int(-1))
        try assertRoundTrip(.int(Int64.max), decodesAs: .int(Int64.max))
    }

    func test_double_roundTrips() throws {
        try assertRoundTrip(.double(1.5), decodesAs: .double(1.5))
        try assertRoundTrip(.double(-3.14), decodesAs: .double(-3.14))
    }

    func test_string_roundTrips() throws {
        try assertRoundTrip(.string(""), decodesAs: .string(""))
        try assertRoundTrip(.string("hello"), decodesAs: .string("hello"))
        try assertRoundTrip(.string("emoji 🎉"), decodesAs: .string("emoji 🎉"))
    }

    func test_array_roundTripsHomogeneous() throws {
        let value: AnyJSONValue = .array([.int(1), .int(2), .int(3)])
        try assertRoundTrip(value, decodesAs: value)
    }

    func test_array_roundTripsHeterogeneous() throws {
        let value: AnyJSONValue = .array([
            .string("a"), .int(1), .bool(true), .null
        ])
        try assertRoundTrip(value, decodesAs: value)
    }

    func test_object_roundTrips() throws {
        let value: AnyJSONValue = .object([
            "name": .string("Peter"),
            "age": .int(33),
            "active": .bool(true),
        ])
        try assertRoundTrip(value, decodesAs: value)
    }

    func test_deeplyNested_roundTrips() throws {
        let value: AnyJSONValue = .object([
            "user": .object([
                "id": .string("u_1"),
                "roles": .array([.string("admin"), .string("ops")]),
                "preferences": .object([
                    "darkMode": .bool(true),
                    "lastSeen": .null,
                ]),
            ]),
            "score": .double(98.6),
        ])
        try assertRoundTrip(value, decodesAs: value)
    }

    // MARK: - Number type discrimination
    //
    // JSONDecoder will try Int64 first, then Double. An integer literal
    // round-trips as `.int`; a fractional literal round-trips as `.double`.

    func test_decoder_prefersIntForWholeNumbers() throws {
        let json = Data("42".utf8)
        let value = try JSONDecoder().decode(AnyJSONValue.self, from: json)
        XCTAssertEqual(value, .int(42))
    }

    func test_decoder_emitsDoubleForFractional() throws {
        let json = Data("1.5".utf8)
        let value = try JSONDecoder().decode(AnyJSONValue.self, from: json)
        XCTAssertEqual(value, .double(1.5))
    }

    // MARK: - Decoding from external JSON

    func test_decoder_acceptsTopLevelNull() throws {
        let json = Data("null".utf8)
        let value = try JSONDecoder().decode(AnyJSONValue.self, from: json)
        XCTAssertEqual(value, .null)
    }

    func test_decoder_acceptsObjectWithMixedTypes() throws {
        let json = Data(#"{"a":1,"b":"x","c":null,"d":[true]}"#.utf8)
        let value = try JSONDecoder().decode(AnyJSONValue.self, from: json)
        guard case .object(let dict) = value else {
            return XCTFail("Expected .object")
        }
        XCTAssertEqual(dict["a"], .int(1))
        XCTAssertEqual(dict["b"], .string("x"))
        XCTAssertEqual(dict["c"], .null)
        XCTAssertEqual(dict["d"], .array([.bool(true)]))
    }

    // MARK: - Encoding output shape

    func test_encoder_objectKeysAndValuesAppearOnTheWire() throws {
        let value: AnyJSONValue = .object([
            "k": .string("v"),
            "n": .int(7),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["k"] as? String, "v")
        XCTAssertEqual(decoded?["n"] as? Int, 7)
    }

    // MARK: - Helpers

    private func assertRoundTrip(
        _ value: AnyJSONValue,
        decodesAs expected: AnyJSONValue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyJSONValue.self, from: data)
        XCTAssertEqual(decoded, expected, file: file, line: line)
    }
}

// MARK: - Coercion from GalvaCompatibleValue

final class AnyJSONValueCoercionTests: XCTestCase {

    func test_bool_coercesToBoolVariant() {
        XCTAssertEqual(AnyJSONValue(true), .bool(true))
        XCTAssertEqual(AnyJSONValue(false), .bool(false))
    }

    func test_int_coercesToInt64Variant() {
        XCTAssertEqual(AnyJSONValue(42 as Int), .int(42))
        XCTAssertEqual(AnyJSONValue(Int64(9_999_999_999)), .int(9_999_999_999))
    }

    func test_double_coercesToDoubleVariant() {
        XCTAssertEqual(AnyJSONValue(1.5 as Double), .double(1.5))
    }

    func test_float_isPromotedToDouble() {
        XCTAssertEqual(AnyJSONValue(Float(2.5)), .double(2.5))
    }

    func test_string_coercesToStringVariant() {
        XCTAssertEqual(AnyJSONValue("hello"), .string("hello"))
    }

    func test_decimal_coercesToStringForLosslessRepresentation() {
        let d = Decimal(string: "9.99")!
        XCTAssertEqual(AnyJSONValue(d), .string("9.99"))
    }

    func test_url_coercesToAbsoluteString() {
        let url = URL(string: "https://example.com/path?q=1")!
        XCTAssertEqual(AnyJSONValue(url), .string("https://example.com/path?q=1"))
    }

    func test_uuid_coercesToLowercasedUUIDString() {
        // Letter-bearing UUID so the lowercase canonicalization is observable;
        // `UUID.uuidString` returns uppercase by default but Galva ships UUIDs
        // lowercased on every wire payload.
        let uuid = UUID(uuidString: "B1FE821D-5597-4ABC-87B6-1F9647CFFD6E")!
        XCTAssertEqual(AnyJSONValue(uuid), .string("b1fe821d-5597-4abc-87b6-1f9647cffd6e"))
    }

    func test_date_coercesToISO8601StringWithFractionalSeconds() {
        // Pin to a known instant.
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        let value = AnyJSONValue(date)
        guard case .string(let s) = value else {
            return XCTFail("Expected .string")
        }
        XCTAssertTrue(s.contains("T"), "ISO 8601 form expected, got: \(s)")
        XCTAssertTrue(s.hasSuffix("Z"), "Expected UTC 'Z' suffix, got: \(s)")
        XCTAssertTrue(s.contains("."), "Expected fractional seconds, got: \(s)")

        // Round-trip via the canonical formatter.
        let parsed = ISO8601DateFormatter.galva.date(from: s)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0,
                       date.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Custom Codable fallback

    private struct Custom: GalvaCompatibleValue, Equatable {
        let name: String
        let count: Int
    }

    func test_customCodableType_fallsThroughToObjectVariant() {
        let value = AnyJSONValue(Custom(name: "x", count: 3))
        guard case .object(let dict) = value else {
            return XCTFail("Expected .object, got \(value)")
        }
        XCTAssertEqual(dict["name"], .string("x"))
        XCTAssertEqual(dict["count"], .int(3))
    }
}
