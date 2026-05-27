//
//  RequestPurchasePayloadTests.swift
//  GalvaTests
//
//  Pure-Swift tests for the bridge's `requestPurchase` payload parsing
//  (BridgeRequest decoder + promotional-offer field shape). The actual
//  StoreKit purchase flow is exercised via integration / device tests
//  because `Product.purchase(options:)` requires a live StoreKit
//  configuration file or the App Store sandbox.
//

import Foundation
@testable import Galva
import XCTest

#if canImport(WebKit)

final class RequestPurchasePayloadTests: XCTestCase {

    // MARK: - BridgeRequest envelope

    func test_envelope_decodesProductIdOnly() throws {
        let json = #"""
        {
          "name": "requestPurchase",
          "requestId": "rq-1",
          "payload": { "productId": "com.app.pro.year" }
        }
        """#
        let req = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.name, .requestPurchase)
        XCTAssertEqual(req.payload?["productId"], .string("com.app.pro.year"))
        XCTAssertNil(req.payload?["promotionalOffer"])
    }

    func test_envelope_decodesProductIdAndJWSPromotionalOffer() throws {
        // The wire shape is JWS-only: `{ offerId, signature }` where
        // `signature` is a JWS compact string. The legacy 5-tuple shape
        // (keyId, nonce, base64 signature, timestamp) has been retired.
        let json = #"""
        {
          "name": "requestPurchase",
          "requestId": "rq-2",
          "payload": {
            "productId": "com.app.pro.month",
            "promotionalOffer": {
              "offerId":   "promo_winter_25",
              "signature": "eyJraWQiOiJBQkMxMjMifQ.eyJvZmZlcklEIjoicHJvbW9fd2ludGVyXzI1In0.SGVsbG8tV29ybGQ"
            }
          }
        }
        """#
        let req = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.name, .requestPurchase)
        guard case .object(let promo)? = req.payload?["promotionalOffer"] else {
            return XCTFail("expected promotionalOffer object")
        }
        XCTAssertEqual(promo["offerId"], .string("promo_winter_25"))
        // Three base64url segments separated by dots — canonical JWS shape.
        guard case .string(let jws)? = promo["signature"] else {
            return XCTFail("signature must decode as String")
        }
        XCTAssertEqual(jws.split(separator: ".").count, 3,
                       "signature must be a JWS compact serialization")
    }

    // MARK: - JWS shape sanity check (NativeBridge.isLikelyJWS)
    //
    // NativeBridge is gated on UIKit (it implements WKScriptMessageHandler
    // which is iOS-only in the WebKit headers we depend on), so these
    // tests only run on iOS / Mac Catalyst targets.

    #if canImport(UIKit)
    @MainActor
    func test_isLikelyJWS_acceptsValidCompactJWS() {
        XCTAssertTrue(NativeBridge.isLikelyJWS(
            "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJnYWx2YSJ9.MEUCIQDsig"
        ))
    }

    @MainActor
    func test_isLikelyJWS_rejectsWrongSegmentCount() {
        XCTAssertFalse(NativeBridge.isLikelyJWS("one"))
        XCTAssertFalse(NativeBridge.isLikelyJWS("one.two"))
        XCTAssertFalse(NativeBridge.isLikelyJWS("one.two.three.four"))
    }

    @MainActor
    func test_isLikelyJWS_rejectsEmptySegment() {
        XCTAssertFalse(NativeBridge.isLikelyJWS(".header.signature"))
        XCTAssertFalse(NativeBridge.isLikelyJWS("header..signature"))
        XCTAssertFalse(NativeBridge.isLikelyJWS("header.payload."))
    }

    @MainActor
    func test_isLikelyJWS_rejectsNonBase64URLCharacters() {
        // Plus and slash are valid in standard base64 but NOT base64url —
        // JWS compact serialization is strictly base64url-encoded.
        XCTAssertFalse(NativeBridge.isLikelyJWS("a+b.c.d"))
        XCTAssertFalse(NativeBridge.isLikelyJWS("a.b/c.d"))
        XCTAssertFalse(NativeBridge.isLikelyJWS("a.b=.c"))
    }
    #endif

    // MARK: - BridgeError purchase codes round-trip

    func test_bridgeError_purchaseCodes_roundTripThroughJSON() throws {
        let codes: [BridgeError.Code] = [
            .productUnavailable,
            .purchaseNotAllowed,
            .ineligibleForOffer,
            .invalidOffer,
            .verificationFailed,
            .networkError,
            .notAvailableInStorefront,
            .purchaseFailed,
        ]
        for code in codes {
            let err = BridgeError(code: code, message: "test")
            let encoded = try JSONEncoder().encode(err)
            let decoded = try JSONDecoder().decode(BridgeError.self, from: encoded)
            XCTAssertEqual(decoded.code, code, "code \(code.rawValue) must round-trip")
        }
    }

    // MARK: - BridgeResponse outcome shapes the bundle reads

    func test_purchaseResponse_successOutcome_encodesCompletedShape() throws {
        // The bridge encodes completed/pending/cancelled into the
        // success branch's `result` payload. This test pins the shape
        // the bundle's JavaScript switches on.
        let completed: AnyJSONValue = .object([
            "outcome": .string("completed"),
            "transaction": .object([
                "id": .string("12345"),
                "originalId": .string("12345"),
                "productId": .string("com.app.pro"),
                "verified": .bool(true),
            ]),
        ])
        let response = BridgeResponse(requestId: "rq", result: completed)
        let data = try JSONEncoder().encode(response)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        XCTAssertEqual(result["outcome"] as? String, "completed")
        let tx = try XCTUnwrap(result["transaction"] as? [String: Any])
        XCTAssertEqual(tx["productId"] as? String, "com.app.pro")
        XCTAssertEqual(tx["verified"] as? Bool, true)
        XCTAssertNil(obj["error"])
    }

    func test_purchaseResponse_cancelledOutcome_isSuccessBranch() throws {
        // User cancel is a flow outcome, not an error. Encoded as a
        // success result so the bundle doesn't fire an error toast.
        let cancelled: AnyJSONValue = .object(["outcome": .string("cancelled")])
        let response = BridgeResponse(requestId: "rq", result: cancelled)
        let data = try JSONEncoder().encode(response)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(obj["result"])
        XCTAssertNil(obj["error"], "user cancel must not be encoded as an error")
    }

    func test_purchaseResponse_pendingOutcome_isSuccessBranch() throws {
        // Ask to Buy / SCA is pending — the transaction will arrive
        // later via Transaction.updates. Also success branch.
        let pending: AnyJSONValue = .object(["outcome": .string("pending")])
        let response = BridgeResponse(requestId: "rq", result: pending)
        let data = try JSONEncoder().encode(response)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(obj["result"])
        XCTAssertNil(obj["error"])
    }

    func test_purchaseResponse_genuineError_usesErrorBranch() throws {
        let err = BridgeError(code: .ineligibleForOffer, message: "Already redeemed")
        let response = BridgeResponse(requestId: "rq", error: err)
        let data = try JSONEncoder().encode(response)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(obj["result"])
        let errObj = try XCTUnwrap(obj["error"] as? [String: String])
        XCTAssertEqual(errObj["code"], "ineligibleForOffer")
    }
}

#endif // canImport(WebKit)
