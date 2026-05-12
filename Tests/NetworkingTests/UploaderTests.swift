//
//  UploaderTests.swift
//  GalvaTests
//
//  Two concerns:
//
//    1. Request shape — POST /identities/batchCollect, correct headers,
//       JSON body matches the OpenAPI envelope (messages + sentAt).
//
//    2. Status classification — every status code maps to the documented
//       UploadOutcome variant:
//         2xx             → .success
//         408, 429        → .retryable
//         5xx             → .retryable
//         4xx (other)     → .permanent
//         transport error → .retryable
//         encoding error  → .permanent
//
//  All HTTP is intercepted via URLProtocolStub — no real sockets opened.
//

import Foundation
@testable import Galva
import XCTest

final class UploaderRequestShapeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func test_request_targetsBatchCollectPath() async throws {
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { request in
            let url = request.url!
            return (URLProtocolStub.httpResponse(url: url, status: 200), Data())
        }

        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "pk_test_x",
            session: session,
            logger: SilentLogger()
        )
        _ = await uploader.upload(messages: [sampleMessage()])

        let url = try XCTUnwrap(URLProtocolStub.lastRequest?.url)
        XCTAssertEqual(url.absoluteString, "https://api.galva.dev/identities/batchCollect")
    }

    func test_request_isPOST() async throws {
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200), Data())
        }
        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "k",
            session: session,
            logger: SilentLogger()
        )
        _ = await uploader.upload(messages: [sampleMessage()])

        XCTAssertEqual(URLProtocolStub.lastRequest?.httpMethod, "POST")
    }

    func test_request_includesRequiredHeaders() async throws {
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200), Data())
        }
        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "pk_live_abc",
            session: session,
            logger: SilentLogger()
        )
        _ = await uploader.upload(messages: [sampleMessage()])

        let headers = URLProtocolStub.lastRequest?.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["X-API-Key"], "pk_live_abc")
        XCTAssertEqual(headers["x-sdk-version"], SDKConstants.sdkVersionHeader)
        XCTAssertEqual(headers["Content-Type"], "application/json")
    }

    func test_request_bodyIsBatchCollectEnvelope() async throws {
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200), Data())
        }
        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "k",
            session: session,
            logger: SilentLogger()
        )

        let messages = [sampleMessage(event: "first"), sampleMessage(event: "second")]
        _ = await uploader.upload(messages: messages)

        let body = try XCTUnwrap(URLProtocolStub.lastRequest?.httpBody)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertNotNil(envelope["sentAt"] as? String, "sentAt must be ISO 8601 string")
        let arr = try XCTUnwrap(envelope["messages"] as? [[String: Any]])
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr.map { $0["event"] as? String }, ["first", "second"])
    }

    func test_emptyBatch_returnsSuccessWithoutMakingRequest() async {
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { _ in
            XCTFail("Empty batch should not hit the wire")
            return (URLProtocolStub.httpResponse(url: URL(string: "https://x")!, status: 500), nil)
        }
        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "k",
            session: session,
            logger: SilentLogger()
        )
        let outcome = await uploader.upload(messages: [])
        guard case .success = outcome else {
            return XCTFail("Empty batch must return .success")
        }
        XCTAssertEqual(URLProtocolStub.requests.count, 0)
    }
}

// MARK: - Status classification

final class UploaderStatusClassificationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: 2xx → success

    func test_status200_isSuccess() async {
        await assertOutcome(forStatus: 200, isSuccess)
    }

    func test_status204_isSuccess() async {
        await assertOutcome(forStatus: 204, isSuccess)
    }

    func test_status299_isSuccess() async {
        await assertOutcome(forStatus: 299, isSuccess)
    }

    // MARK: 408 / 429 → retryable

    func test_status408_isRetryable() async {
        await assertOutcome(forStatus: 408, isRetryable)
    }

    func test_status429_isRetryable() async {
        await assertOutcome(forStatus: 429, isRetryable)
    }

    // MARK: 5xx → retryable

    func test_status500_isRetryable() async {
        await assertOutcome(forStatus: 500, isRetryable)
    }

    func test_status503_isRetryable() async {
        await assertOutcome(forStatus: 503, isRetryable)
    }

    func test_status599_isRetryable() async {
        await assertOutcome(forStatus: 599, isRetryable)
    }

    // MARK: 4xx (other) → permanent

    func test_status400_isPermanent() async {
        await assertOutcome(forStatus: 400, isPermanent)
    }

    func test_status401_isPermanent() async {
        await assertOutcome(forStatus: 401, isPermanent)
    }

    func test_status403_isPermanent() async {
        await assertOutcome(forStatus: 403, isPermanent)
    }

    func test_status404_isPermanent() async {
        await assertOutcome(forStatus: 404, isPermanent)
    }

    // MARK: transport failures → retryable

    func test_transportError_isRetryable() async {
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "k",
            session: session,
            logger: SilentLogger()
        )
        let outcome = await uploader.upload(messages: [sampleMessage()])
        XCTAssertTrue(isRetryable(outcome), "Transport error must classify as retryable; got \(outcome)")
    }

    // MARK: - Helpers

    private func assertOutcome(
        forStatus status: Int,
        _ check: (UploadOutcome) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        URLProtocolStub.reset()
        let session = URLProtocolStub.makeSession()
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: status),
             Data(#"{"error":"x"}"#.utf8))
        }
        let uploader = Uploader(
            baseURL: URL(string: "https://api.galva.dev")!,
            apiKey: "k",
            session: session,
            logger: SilentLogger()
        )
        let outcome = await uploader.upload(messages: [sampleMessage()])
        XCTAssertTrue(check(outcome),
                      "Status \(status) classification failed; got \(outcome)",
                      file: file, line: line)
    }

    private func isSuccess(_ o: UploadOutcome) -> Bool {
        if case .success = o { return true }
        return false
    }
    private func isRetryable(_ o: UploadOutcome) -> Bool {
        if case .retryable = o { return true }
        return false
    }
    private func isPermanent(_ o: UploadOutcome) -> Bool {
        if case .permanent = o { return true }
        return false
    }
}

// MARK: - Fixtures

private func sampleMessage(event: String = "test") -> Message {
    Message(
        anonymousId: "anon",
        endUserId: nil,
        context: nil,
        body: .track(event: event, properties: nil, sourceType: nil, sourceId: nil)
    )
}

/// No-op logger so test output stays clean.
struct SilentLogger: GalvaLogger {
    func log(_ entry: Galva.LogEntry) {}
}
