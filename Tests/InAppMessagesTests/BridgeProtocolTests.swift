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
#if canImport(UIKit)
import UIKit
#endif

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
            .apiFetch,
            .showAlert,
        ] {
            let json = #"{"name":"\#(method.rawValue)","requestId":"req-1","payload":{}}"#
            let data = Data(json.utf8)
            let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
            XCTAssertEqual(request.name, method.rawValue)
            XCTAssertEqual(request.method, method)
            XCTAssertEqual(request.requestId, "req-1")
        }
    }

    func test_bridgeRequest_unknownMethod_decodesWithNilMethod() throws {
        // Unknown names must still decode — the dispatcher answers with an
        // unknownMethod error carrying the requestId rather than dropping the
        // call (which would hang the bundle's Promise). `method` resolves nil.
        let json = #"{"name":"nope","requestId":"x","payload":{}}"#
        let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.name, "nope")
        XCTAssertNil(request.method)
        XCTAssertEqual(request.requestId, "x")
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

    func test_bridgeError_apiRequestFailed_roundTrips() throws {
        let err = BridgeError(code: .apiRequestFailed, message: "offline")
        let data = try JSONEncoder().encode(err)
        let decoded = try JSONDecoder().decode(BridgeError.self, from: data)
        XCTAssertEqual(decoded.code, .apiRequestFailed)
        XCTAssertEqual(decoded.message, "offline")
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

// MARK: - apiFetch request/response marshaling (NativeBridge static helpers)

@MainActor
final class BridgeAPIFetchMarshalingTests: XCTestCase {

    // MARK: parseAPIFetch — validation

    func test_parse_requiresNonEmptyPath() {
        for payload: [String: AnyJSONValue]? in [nil, [:], ["path": .string("  ")]] {
            guard case .failure(let error) = NativeBridge.parseAPIFetch(payload) else {
                return XCTFail("expected failure for payload \(String(describing: payload))")
            }
            XCTAssertEqual(error.code, .invalidPayload)
        }
    }

    func test_parse_defaultsMethodToGET() {
        guard case .success(let parsed) = NativeBridge.parseAPIFetch(["path": .string("/x")]) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(parsed.method, "GET")
        XCTAssertNil(parsed.body)
        XCTAssertEqual(parsed.path, "/x")
    }

    func test_parse_upperCasesMethod() {
        guard case .success(let parsed) = NativeBridge.parseAPIFetch([
            "path": .string("/x"), "method": .string("post"),
        ]) else { return XCTFail("expected success") }
        XCTAssertEqual(parsed.method, "POST")
    }

    func test_parse_rejectsDisallowedMethod() {
        guard case .failure(let error) = NativeBridge.parseAPIFetch([
            "path": .string("/x"), "method": .string("TRACE"),
        ]) else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    // MARK: parseAPIFetch — body / headers

    func test_parse_stringBody_isRawUTF8_noContentTypeAdded() {
        guard case .success(let parsed) = NativeBridge.parseAPIFetch([
            "path": .string("/x"), "method": .string("POST"), "body": .string("raw text"),
        ]) else { return XCTFail("expected success") }
        XCTAssertEqual(parsed.body, Data("raw text".utf8))
        XCTAssertNil(parsed.headers["Content-Type"])
    }

    func test_parse_objectBody_isJSONEncoded_withDefaultContentType() throws {
        guard case .success(let parsed) = NativeBridge.parseAPIFetch([
            "path": .string("/x"),
            "method": .string("POST"),
            "body": .object(["hello": .string("world")]),
        ]) else { return XCTFail("expected success") }
        XCTAssertEqual(parsed.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(parsed.body)
        let decoded = try JSONDecoder().decode(AnyJSONValue.self, from: body)
        XCTAssertEqual(decoded, .object(["hello": .string("world")]))
    }

    func test_parse_objectBody_doesNotOverrideCallerContentType() {
        // Caller's content-type (any case) wins — we don't force JSON on top.
        guard case .success(let parsed) = NativeBridge.parseAPIFetch([
            "path": .string("/x"),
            "method": .string("POST"),
            "body": .object(["a": .int(1)]),
            "headers": .object(["content-type": .string("application/vnd.api+json")]),
        ]) else { return XCTFail("expected success") }
        XCTAssertEqual(parsed.headers["content-type"], "application/vnd.api+json")
        XCTAssertNil(parsed.headers["Content-Type"])
    }

    func test_parse_headers_keepStringsDropOthers() {
        guard case .success(let parsed) = NativeBridge.parseAPIFetch([
            "path": .string("/x"),
            "headers": .object(["Accept": .string("application/json"), "X-Num": .int(7)]),
        ]) else { return XCTFail("expected success") }
        XCTAssertEqual(parsed.headers["Accept"], "application/json")
        XCTAssertNil(parsed.headers["X-Num"])
    }

    func test_parse_nullBody_isNil() {
        guard case .success(let parsed) = NativeBridge.parseAPIFetch([
            "path": .string("/x"), "body": .null,
        ]) else { return XCTFail("expected success") }
        XCTAssertNil(parsed.body)
    }

    // MARK: encodeAPIResponse → typed BridgeAPIFetchResult

    func test_encode_jsonResponse_parsesBody() {
        let response = APIClient.ProxyResponse(
            status: 200,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: Data(#"{"value":42}"#.utf8)
        )
        let result = NativeBridge.encodeAPIResponse(response)
        XCTAssertEqual(result.status, 200)
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.bodyType, .json)
        XCTAssertEqual(result.body, .object(["value": .int(42)]))
    }

    func test_encode_non2xxText_setsOkFalseAndTextBody() {
        let response = APIClient.ProxyResponse(
            status: 404,
            headers: ["content-type": "text/plain"],
            body: Data("nope".utf8)
        )
        let result = NativeBridge.encodeAPIResponse(response)
        XCTAssertEqual(result.status, 404)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.bodyType, .text)
        XCTAssertEqual(result.body, .string("nope"))
    }

    func test_encode_binaryBody_fallsBackToBase64() {
        // Invalid UTF-8 bytes — neither JSON nor text-decodable.
        let raw = Data([0xFF, 0xFE, 0xFD])
        let response = APIClient.ProxyResponse(
            status: 200,
            headers: ["content-type": "application/octet-stream"],
            body: raw
        )
        let result = NativeBridge.encodeAPIResponse(response)
        XCTAssertEqual(result.bodyType, .base64)
        XCTAssertEqual(result.body, .string(raw.base64EncodedString()))
    }

    /// Locks the JSON the hosted page actually receives — the keys come
    /// straight from `BridgeAPIFetchResult`'s Codable synthesis, not a
    /// hand-built dictionary.
    func test_encode_resultEncodesToExpectedWireShape() throws {
        let result = NativeBridge.encodeAPIResponse(APIClient.ProxyResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: Data(#"{"value":42}"#.utf8)
        ))
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? Int, 200)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["bodyType"] as? String, "json")
        XCTAssertEqual((json["headers"] as? [String: String])?["content-type"], "application/json")
        XCTAssertEqual((json["body"] as? [String: Any])?["value"] as? Int, 42)
    }
}

// MARK: - showAlert marshaling (NativeBridge.parseAlert + BridgeAlertResult)

@MainActor
final class BridgeShowAlertMarshalingTests: XCTestCase {

    func test_parseAlert_requiresPayload() {
        guard case .failure(let error) = NativeBridge.parseAlert(nil) else {
            return XCTFail("expected failure for nil payload")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func test_parseAlert_requiresNonEmptyActions() {
        for payload: [String: AnyJSONValue] in [
            ["title": .string("Hi")],                 // no actions key
            ["actions": .array([])],                  // empty actions
        ] {
            guard case .failure(let error) = NativeBridge.parseAlert(payload) else {
                return XCTFail("expected failure for \(payload)")
            }
            XCTAssertEqual(error.code, .invalidPayload)
        }
    }

    func test_parseAlert_parsesTitleMessageAndActions() {
        let payload: [String: AnyJSONValue] = [
            "title": .string("Delete draft?"),
            "message": .string("This can't be undone"),
            "actions": .array([
                .object(["id": .string("delete"), "title": .string("Delete"), "style": .string("destructive")]),
                .object(["id": .string("cancel"), "title": .string("Cancel"), "style": .string("cancel")]),
            ]),
        ]
        guard case .success(let parsed) = NativeBridge.parseAlert(payload) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(parsed.title, "Delete draft?")
        XCTAssertEqual(parsed.message, "This can't be undone")
        XCTAssertEqual(parsed.actions, [
            .init(id: "delete", title: "Delete", style: .destructive),
            .init(id: "cancel", title: "Cancel", style: .cancel),
        ])
    }

    func test_parseAlert_defaultsStyleWhenMissingOrUnknown() {
        let payload: [String: AnyJSONValue] = [
            "actions": .array([
                .object(["id": .string("a"), "title": .string("A")]),                       // no style
                .object(["id": .string("b"), "title": .string("B"), "style": .string("???")]), // unknown
            ]),
        ]
        guard case .success(let parsed) = NativeBridge.parseAlert(payload) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(parsed.actions.map(\.style), [.default, .default])
    }

    func test_parseAlert_omitsNonStringTitle() {
        // A non-string title is treated as absent (optional), not an error.
        let payload: [String: AnyJSONValue] = [
            "title": .int(7),
            "actions": .array([.object(["id": .string("ok"), "title": .string("OK")])]),
        ]
        guard case .success(let parsed) = NativeBridge.parseAlert(payload) else {
            return XCTFail("expected success")
        }
        XCTAssertNil(parsed.title)
    }

    func test_parseAlert_rejectsActionMissingIdOrTitle() {
        let cases: [[String: AnyJSONValue]] = [
            ["actions": .array([.object(["title": .string("OK")])])],          // missing id
            ["actions": .array([.object(["id": .string("ok")])])],             // missing title
            ["actions": .array([.object(["id": .string(""), "title": .string("OK")])])], // empty id
            ["actions": .array([.string("not-an-object")])],                   // wrong shape
        ]
        for payload in cases {
            guard case .failure(let error) = NativeBridge.parseAlert(payload) else {
                return XCTFail("expected failure for \(payload)")
            }
            XCTAssertEqual(error.code, .invalidPayload)
        }
    }

    func test_parseAlert_rejectsMultipleCancelActions() {
        // UIKit crashes on a second .cancel action — we must reject it.
        let payload: [String: AnyJSONValue] = [
            "actions": .array([
                .object(["id": .string("c1"), "title": .string("Cancel"), "style": .string("cancel")]),
                .object(["id": .string("c2"), "title": .string("Nope"), "style": .string("cancel")]),
            ]),
        ]
        guard case .failure(let error) = NativeBridge.parseAlert(payload) else {
            return XCTFail("expected failure for two cancel actions")
        }
        XCTAssertEqual(error.code, .invalidPayload)
    }

    func test_alertResult_encodesToActionId() throws {
        let data = try JSONEncoder().encode(BridgeAlertResult(actionId: "delete"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["actionId"] as? String, "delete")
        XCTAssertEqual(json.count, 1)
    }
}
#endif

#endif // canImport(WebKit)
