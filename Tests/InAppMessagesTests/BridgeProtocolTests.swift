//
//  BridgeProtocolTests.swift
//  GalvaTests
//
//  Round-trips the wire envelopes the WebView bundle and the native bridge
//  exchange, plus a few invariants on JS-injection escaping (the SDK
//  splices the response JSON into an `evaluateJavaScript` source string;
//  every single-quote / newline / line-separator must survive the trip).
//

import Foundation
@testable import Galva
import XCTest

#if canImport(WebKit)

final class BridgeProtocolTests: XCTestCase {

    // MARK: - BridgeRequest round-trip

    func test_bridgeRequest_decodesAllKnownMethods() throws {
        for method in [
            BridgeMethod.ready,
            .dismiss,
            .getPageContext,
            .getMessageData,
            .requestPurchase,
            .openManageSubscription,
            .openDeepLink,
        ] {
            let json = #"{"name":"\#(method.rawValue)","requestId":"req-1","payload":{}}"#
            let data = Data(json.utf8)
            let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
            XCTAssertEqual(request.name, method)
            XCTAssertEqual(request.requestId, "req-1")
        }
    }

    func test_bridgeRequest_rejectsUnknownMethod() {
        let json = #"{"name":"nope","requestId":"x","payload":{}}"#
        XCTAssertThrowsError(
            try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        )
    }

    func test_bridgeRequest_acceptsPayloadShape() throws {
        let json = """
        {
          "name": "requestPurchase",
          "requestId": "abc",
          "payload": {
            "productId": "com.app.premium",
            "offerData": { "signature": "sig", "nonce": "n" }
          }
        }
        """
        let req = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        XCTAssertEqual(req.payload?["productId"], .string("com.app.premium"))
    }

    // MARK: - BridgeResponse round-trip

    func test_bridgeResponse_success_encodesResult() throws {
        let resp = BridgeResponse(
            requestId: "req-2",
            result: .object(["greeting": .string("hi")])
        )
        let data = try JSONEncoder().encode(resp)
        let asJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(asJSON["requestId"] as? String, "req-2")
        XCTAssertNotNil(asJSON["result"])
        XCTAssertNil(asJSON["error"])
    }

    func test_bridgeResponse_failure_encodesError() throws {
        let err = BridgeError(code: .productUnavailable, message: "unknown sku")
        let resp = BridgeResponse(requestId: "req-3", error: err)
        let data = try JSONEncoder().encode(resp)
        let asJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(asJSON["requestId"] as? String, "req-3")
        let errDict = try XCTUnwrap(asJSON["error"] as? [String: String])
        XCTAssertEqual(errDict["code"], "productUnavailable")
        XCTAssertEqual(errDict["message"], "unknown sku")
    }
}

// MARK: - JS string escape (NativeBridge.escapeForJSStringLiteral)

#if canImport(UIKit)
@MainActor
final class BridgeJSEscapeTests: XCTestCase {

    func test_escape_preservesPlainText() {
        XCTAssertEqual(NativeBridge.escapeForJSStringLiteral("hello"), "hello")
    }

    func test_escape_singleQuote() {
        XCTAssertEqual(NativeBridge.escapeForJSStringLiteral("it's"), "it\\'s")
    }

    func test_escape_backslash() {
        XCTAssertEqual(NativeBridge.escapeForJSStringLiteral("a\\b"), "a\\\\b")
    }

    func test_escape_newlines() {
        XCTAssertEqual(
            NativeBridge.escapeForJSStringLiteral("line1\nline2\r"),
            "line1\\nline2\\r"
        )
    }

    func test_escape_jsLineSeparators() {
        // U+2028 / U+2029 are valid in JSON strings but break out of JS
        // single-quoted literals when un-escaped (JS treats them as
        // line terminators).
        let raw = "before\u{2028}after\u{2029}end"
        XCTAssertEqual(
            NativeBridge.escapeForJSStringLiteral(raw),
            "before\\u2028after\\u2029end"
        )
    }
}
#endif

#endif // canImport(WebKit)
