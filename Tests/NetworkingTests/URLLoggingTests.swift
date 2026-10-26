//
//  URLLoggingTests.swift
//  GalvaTests
//
//  The SDK logs a request by its path, never its query string. The in-app
//  poll sends endUserId and anonymousId in its query, and a non-2xx answer
//  is logged at .warning — the default level — which `OSLogLogger` writes
//  as public and any custom `GalvaLogger` (Crashlytics, Sentry, …)
//  receives as is.
//
//  A `RecordingLogger` captures every level, so the .debug request traces
//  are checked along with the .warning. A failed request's error is logged
//  too (the poll logs it), and URLSession puts the whole URL in it.
//

import Foundation
@testable import Galva
import XCTest

final class URLLoggingTests: XCTestCase {

    private static let base = URL(string: "https://api.galva.io")!
    private static let endUserId = "ravi@example.com"
    private static let anonymousId = "0f1e2d3c-anon"

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - APIClient

    func test_rpcFailure_warningLogsThePath_notTheQuery() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url ?? Self.base, status: 404), Data())
        }
        let logger = RecordingLogger()

        let _: Empty? = try? await makeClient(logger: logger).get(
            path: SDKConstants.communicationListPath,
            query: Self.identityQuery
        )

        let warning = logger.entries.first { $0.level == .warning }
        XCTAssertEqual(warning?.metadata["path"], "/identities/communications")
        assertNoIdentifiers(in: logger.entries)
    }

    func test_rpcSuccess_traceLogsThePath_notTheQuery() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url ?? Self.base, status: 200), Data("{}".utf8))
        }
        let logger = RecordingLogger()

        let _: Empty = try await makeClient(logger: logger).get(
            path: SDKConstants.communicationListPath,
            query: Self.identityQuery
        )

        XCTAssertFalse(logger.entries.isEmpty, "the request is traced at .debug")
        XCTAssertTrue(logger.entries.allSatisfy { $0.metadata["path"] == "/identities/communications" })
        assertNoIdentifiers(in: logger.entries)
    }

    func test_proxyRequest_logsThePath_notTheQuery() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url ?? Self.base, status: 200), Data())
        }
        let logger = RecordingLogger()

        _ = try await makeClient(logger: logger).proxyRequest(
            path: "/things?endUserId=\(Self.endUserId)&anonymousId=\(Self.anonymousId)",
            method: "GET",
            body: nil,
            additionalHeaders: [:]
        )

        XCTAssertFalse(logger.entries.isEmpty, "the proxied request is traced at .debug")
        XCTAssertTrue(logger.entries.allSatisfy { $0.metadata["path"] == "/things" })
        assertNoIdentifiers(in: logger.entries)
    }

    func test_transportError_doesNotCarryTheQuery() async {
        // What URLSession hands back when the device is offline: the failing
        // URL, query and all, in the error's user info.
        URLProtocolStub.handler = { request in
            throw URLError(.notConnectedToInternet, userInfo: [
                NSURLErrorFailingURLErrorKey: request.url as Any,
                NSURLErrorFailingURLStringErrorKey: request.url?.absoluteString as Any,
            ])
        }

        do {
            let _: Empty = try await makeClient(logger: RecordingLogger()).get(
                path: SDKConstants.communicationListPath,
                query: Self.identityQuery
            )
            XCTFail("expected a transport error")
        } catch let error as APIError {
            guard case .transport(let underlying) = error else {
                return XCTFail("expected .transport, got \(error)")
            }
            XCTAssertEqual((underlying as? URLError)?.code, .notConnectedToInternet)
            let logged = String(describing: error)
            XCTAssertFalse(logged.contains(Self.endUserId), logged)
            XCTAssertFalse(logged.contains(Self.anonymousId), logged)
        } catch {
            XCTFail("expected an APIError, got \(error)")
        }
    }

    // MARK: - Durable apiFetch queue

    func test_durableRequestDropped_warningLogsThePath_notTheQuery() async {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url ?? Self.base, status: 404), Data())
        }
        let logger = RecordingLogger()

        await DurableHarness.enqueue(
            path: "/things?endUserId=\(Self.endUserId)&anonymousId=\(Self.anonymousId)",
            client: makeClient(logger: logger),
            logger: logger
        )

        let dropped = logger.entries.first { $0.message.contains("permanent failure") }
        XCTAssertEqual(dropped?.metadata["path"], "/things")
        assertNoIdentifiers(in: logger.entries)
    }

    // MARK: - Log formatting

    func test_loggablePath_dropsQueryAndFragment() {
        let url = URL(string: "https://api.galva.io/identities/communications?endUserId=\(Self.endUserId)#x")!
        XCTAssertEqual(url.loggablePath, "/identities/communications")
        XCTAssertEqual("/things?endUserId=\(Self.endUserId)".loggablePath, "/things")
        XCTAssertEqual("/things#anonymousId=\(Self.anonymousId)".loggablePath, "/things")
        XCTAssertEqual("/things".loggablePath, "/things")
    }

    func test_loggableLocation_keepsSchemeHostAndPath_only() {
        // URLs outside the Galva API (a page the WebView was sent to, a link
        // the page opens): the host is the useful part; the rest goes.
        let url = URL(string: "https://user:secret@example.com/manage?token=abc#frag")!
        XCTAssertEqual(url.loggableLocation, "https://example.com/manage")
        XCTAssertEqual(URL(string: "myapp://offers/42?endUserId=\(Self.endUserId)")!.loggableLocation,
                       "myapp://offers/42")
    }

    // MARK: - Helpers

    private static let identityQuery = [
        URLQueryItem(name: "channelType", value: "in-app"),
        URLQueryItem(name: "endUserId", value: endUserId),
        URLQueryItem(name: "anonymousId", value: anonymousId),
    ]

    private struct Empty: Decodable {}

    private func makeClient(logger: any GalvaLogger) -> APIClient {
        APIClient(
            baseURL: Self.base,
            apiKey: "pk_test",
            session: URLProtocolStub.makeSession(),
            logger: logger
        )
    }

    /// No entry's message or metadata carries either identifier, or any
    /// query string at all.
    private func assertNoIdentifiers(
        in entries: [Galva.LogEntry],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for entry in entries {
            for text in [entry.message] + Array(entry.metadata.values) {
                XCTAssertFalse(text.contains(Self.endUserId), "\(entry.message): \(text)", file: file, line: line)
                XCTAssertFalse(text.contains(Self.anonymousId), "\(entry.message): \(text)", file: file, line: line)
                XCTAssertFalse(text.contains("?"), "\(entry.message): \(text)", file: file, line: line)
            }
        }
    }

    @GalvaActor
    private enum DurableHarness {
        static func enqueue(path: String, client: APIClient, logger: any GalvaLogger) async {
            let queue = DurableRequestQueue(
                store: InMemoryProxyRequestStore(),
                client: client,
                logger: logger
            )
            await queue.enqueue(path: path, method: "POST", body: nil, headers: [:])
        }
    }
}
