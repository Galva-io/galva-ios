//
//  URLProtocolStub.swift
//  GalvaTests
//
//  In-process URLProtocol that captures outgoing requests and returns
//  canned responses. Tests configure it via a static handler, then build
//  a URLSession with the stub class in `protocolClasses` — that way the
//  intercept is scoped to the test's session and never leaks to other
//  tests or to production code paths sharing `.shared`.
//
//  Usage:
//      let session = URLProtocolStub.makeSession { request in
//          (HTTPURLResponse(...)!, Data())
//      }
//      // ...exercise code that uses `session`...
//      let captured = URLProtocolStub.lastRequest
//

import Foundation

final class URLProtocolStub: URLProtocol {

    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

    // MARK: Shared state (per test)

    /// Set this before exercising the session under test.
    nonisolated(unsafe) static var handler: Handler?

    /// Captured requests, in chronological order. Tests assert on this.
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static var lastRequest: URLRequest? { requests.last }

    /// Reset between tests — XCTestCase.setUp / tearDown should call this.
    static func reset() {
        handler = nil
        requests = []
    }

    /// Build a URLSession that intercepts every request via this protocol.
    /// Each test gets its own session — never reuse across tests.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    // MARK: URLProtocol

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = URLProtocolStub.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        // The request the host code built. URLSession sometimes strips the
        // httpBody and re-attaches it as httpBodyStream; capture both.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = Self.read(stream: stream)
        }
        URLProtocolStub.requests.append(captured)

        do {
            let (response, data) = try handler(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    // MARK: - Helpers

    private static func read(stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var buffer = Data()
        let chunk = 4096
        var raw = [UInt8](repeating: 0, count: chunk)
        while stream.hasBytesAvailable {
            let n = stream.read(&raw, maxLength: chunk)
            if n <= 0 { break }
            buffer.append(raw, count: n)
        }
        return buffer
    }
}

// MARK: - Tiny response helpers

extension URLProtocolStub {
    /// Convenience for handler closures.
    static func httpResponse(
        url: URL,
        status: Int,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}
