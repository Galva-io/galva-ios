//
//  APIClientProxyTests.swift
//  GalvaTests
//
//  Covers `APIClient.proxyRequest(...)` and its `resolveProxyURL` guard —
//  the networking half of the WebView `apiFetch` bridge.
//
//  Two concerns:
//    1. SECURITY — the hosted bundle supplies only a relative path. It must
//       not be able to redirect the authenticated request to another origin
//       (SSRF) or spoof the API key.
//    2. TRANSPARENCY — the raw HTTP outcome (including non-2xx) is returned
//       verbatim so the bridge can hand status + body to the page.
//

import Foundation
@testable import Galva
import XCTest

final class APIClientProxyTests: XCTestCase {

    // `static` so the `@Sendable` URLProtocolStub handler closures can
    // reference it without capturing the non-Sendable XCTestCase `self`.
    private static let base = URL(string: "https://api.galva.io")!

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - resolveProxyURL (pure, no session)

    func test_resolveProxyURL_acceptsLeadingSlashPath() {
        let url = APIClient.resolveProxyURL(path: "/identities/communications", base: Self.base)
        XCTAssertEqual(url?.absoluteString, "https://api.galva.io/identities/communications")
    }

    func test_resolveProxyURL_addsLeadingSlashWhenMissing() {
        let url = APIClient.resolveProxyURL(path: "sdk/initialize", base: Self.base)
        XCTAssertEqual(url?.absoluteString, "https://api.galva.io/sdk/initialize")
    }

    func test_resolveProxyURL_preservesQueryString() {
        let url = APIClient.resolveProxyURL(path: "/x?a=b&c=d", base: Self.base)
        XCTAssertEqual(url?.absoluteString, "https://api.galva.io/x?a=b&c=d")
    }

    func test_resolveProxyURL_rejectsAbsoluteURL() {
        XCTAssertNil(APIClient.resolveProxyURL(path: "https://evil.com/steal", base: Self.base))
        XCTAssertNil(APIClient.resolveProxyURL(path: "http://api.galva.io/x", base: Self.base))
    }

    func test_resolveProxyURL_rejectsSchemeRelativeURL() {
        // "//evil.com/x" resolves to https://evil.com/x against an https base —
        // the classic protocol-relative SSRF vector. Must be refused.
        XCTAssertNil(APIClient.resolveProxyURL(path: "//evil.com/x", base: Self.base))
    }

    func test_resolveProxyURL_rejectsEmptyOrWhitespace() {
        XCTAssertNil(APIClient.resolveProxyURL(path: "", base: Self.base))
        XCTAssertNil(APIClient.resolveProxyURL(path: "   ", base: Self.base))
    }

    // MARK: - proxyRequest (via stubbed session)

    func test_proxyRequest_buildsURLAndInjectsAuthHeaders() async throws {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data("{}".utf8))
        }
        let client = makeClient()
        _ = try await client.proxyRequest(
            path: "/identities/communications",
            method: "GET",
            body: nil,
            additionalHeaders: [:]
        )
        let captured = try XCTUnwrap(URLProtocolStub.lastRequest)
        XCTAssertEqual(captured.url?.absoluteString, "https://api.galva.io/identities/communications")
        XCTAssertEqual(captured.httpMethod, "GET")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-API-Key"), "pk_test")
        XCTAssertNotNil(captured.value(forHTTPHeaderField: "x-sdk-version"))
    }

    func test_proxyRequest_forwardsMethodBodyAndCallerHeaders() async throws {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 201), Data())
        }
        let client = makeClient()
        let body = Data(#"{"hello":"world"}"#.utf8)
        _ = try await client.proxyRequest(
            path: "/things",
            method: "POST",
            body: body,
            additionalHeaders: ["Content-Type": "application/json", "X-Custom": "abc"]
        )
        let captured = try XCTUnwrap(URLProtocolStub.lastRequest)
        XCTAssertEqual(captured.httpMethod, "POST")
        XCTAssertEqual(captured.httpBody, body)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-Custom"), "abc")
    }

    func test_proxyRequest_callerCannotOverrideAPIKey() async throws {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 200), Data())
        }
        let client = makeClient()
        // Both exact-case and lowercase attempts must be stripped.
        _ = try await client.proxyRequest(
            path: "/x",
            method: "GET",
            body: nil,
            additionalHeaders: ["X-API-Key": "hacked", "x-api-key": "hacked2"]
        )
        let captured = try XCTUnwrap(URLProtocolStub.lastRequest)
        XCTAssertEqual(captured.value(forHTTPHeaderField: "X-API-Key"), "pk_test")
        // Defense in depth: the spoofed value must appear nowhere in the headers.
        let allValues = (captured.allHTTPHeaderFields ?? [:]).values
        XCTAssertFalse(allValues.contains("hacked"))
        XCTAssertFalse(allValues.contains("hacked2"))
    }

    func test_proxyRequest_returnsStatusHeadersAndBody() async throws {
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(
                url: Self.base,
                status: 200,
                headers: ["Content-Type": "application/json"]
            ), Data(#"{"ok":true}"#.utf8))
        }
        let client = makeClient()
        let response = try await client.proxyRequest(path: "/x", method: "GET", body: nil, additionalHeaders: [:])
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
    }

    func test_proxyRequest_doesNotThrowOnNon2xx() async throws {
        // Non-2xx is a normal outcome here — the bridge surfaces it to the
        // page rather than turning it into a Promise rejection.
        URLProtocolStub.handler = { _ in
            (URLProtocolStub.httpResponse(url: Self.base, status: 404), Data("not found".utf8))
        }
        let client = makeClient()
        let response = try await client.proxyRequest(path: "/missing", method: "GET", body: nil, additionalHeaders: [:])
        XCTAssertEqual(response.status, 404)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "not found")
    }

    func test_proxyRequest_throwsMalformedURLOnDisallowedPath() async {
        let client = makeClient()
        do {
            _ = try await client.proxyRequest(
                path: "https://evil.com/x",
                method: "GET",
                body: nil,
                additionalHeaders: [:]
            )
            XCTFail("expected malformedURL for an absolute path")
        } catch let error as APIError {
            guard case .malformedURL = error else {
                return XCTFail("expected .malformedURL, got \(error)")
            }
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func makeClient() -> APIClient {
        APIClient(
            baseURL: Self.base,
            apiKey: "pk_test",
            session: URLProtocolStub.makeSession(),
            logger: SilentLogger()
        )
    }
}
