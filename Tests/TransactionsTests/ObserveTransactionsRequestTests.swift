//
//  ObserveTransactionsRequestTests.swift
//  GalvaTests
//
//  Wire-format pin for `POST /v1/transactions/observe`. The Galva
//  backend reconciles App Store Server Notifications by joining on
//  `originalTransactionId`; if we accidentally reshape the request the
//  whole organic-purchase mapping path goes dark. Lock the shape with
//  explicit encode/decode assertions.
//

import Foundation
@testable import Galva
import XCTest

#if canImport(StoreKit)

final class ObserveTransactionsRequestTests: XCTestCase {

    func test_encode_producesExpectedJSON() throws {
        let req = ObserveTransactionsRequest(
            anonymousId: "anon_abc",
            endUserId: "user_42",
            transactions: [
                .init(originalTransactionId: "1000000123456789"),
                .init(originalTransactionId: "1000000987654321"),
            ]
        )
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(obj["anonymousId"] as? String, "anon_abc")
        XCTAssertEqual(obj["endUserId"] as? String, "user_42")
        let txs = try XCTUnwrap(obj["transactions"] as? [[String: Any]])
        XCTAssertEqual(txs.count, 2)
        XCTAssertEqual(txs[0]["originalTransactionId"] as? String, "1000000123456789")
        XCTAssertEqual(txs[1]["originalTransactionId"] as? String, "1000000987654321")
    }

    func test_encode_omitsEndUserId_whenAnonymous() throws {
        let req = ObserveTransactionsRequest(
            anonymousId: "anon_only",
            endUserId: nil,
            transactions: [.init(originalTransactionId: "777")]
        )
        let data = try JSONEncoder().encode(req)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // JSONEncoder drops nil optionals by default — anonymous-only
        // sessions must produce a request with no `endUserId` key, so
        // the backend can't accidentally read a literal `null` as the
        // string "null".
        XCTAssertNil(obj["endUserId"])
        XCTAssertEqual(obj["anonymousId"] as? String, "anon_only")
    }

    func test_roundTrip_preservesAllFields() throws {
        let original = ObserveTransactionsRequest(
            anonymousId: "anon",
            endUserId: "user",
            transactions: [
                .init(originalTransactionId: "111"),
                .init(originalTransactionId: "222"),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ObserveTransactionsRequest.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - EmptyAPIResponse decoder

    func test_emptyResponse_acceptsEmptyObject() throws {
        // The /v1/transactions/observe endpoint may return any 2xx body
        // shape — empty object, full meta/data envelope, etc. The
        // EmptyAPIResponse decoder must accept all of them so a
        // server-side schema change doesn't break the sweep.
        for shape in ["{}", #"{"meta":{"requestId":"x"}}"#, #"{"any":"thing"}"#] {
            XCTAssertNoThrow(
                try JSONDecoder().decode(EmptyAPIResponse.self, from: Data(shape.utf8)),
                "EmptyAPIResponse must accept: \(shape)"
            )
        }
    }

    func test_emptyResponse_acceptsNullBody() throws {
        XCTAssertNoThrow(
            try JSONDecoder().decode(EmptyAPIResponse.self, from: Data("null".utf8))
        )
    }
}

#endif // canImport(StoreKit)
