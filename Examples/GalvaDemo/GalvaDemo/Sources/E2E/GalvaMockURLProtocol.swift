//
//  GalvaMockURLProtocol.swift
//  GalvaDemo
//
//  In-process mock transport. Registered at launch in E2E mode, it claims any
//  request to `*.galva.test` and replays canned fixtures — covering every
//  endpoint the SDK hits (init, poll, resolve, batchCollect, transactions,
//  and the `<cdn>/<version>.html` bundle). Works because the SDK routes all
//  traffic through `URLSession.shared`, which a globally-registered
//  URLProtocol intercepts. No server, no ports, no ATS exceptions.
//

import Foundation

final class GalvaMockURLProtocol: URLProtocol {

    /// Active scenario, set once at launch (before any request) and read on
    /// URL loading threads.
    nonisolated(unsafe) static var scenario: E2EScenario = .showInAppMessage

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.hasSuffix("galva.test")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            finish(status: 400, json: "{}")
            return
        }
        let host = url.host ?? ""
        let path = url.path
        let method = (request.httpMethod ?? "GET").uppercased()

        // WebView bundle download (no auth, GET <cdn>/<version>.html).
        if host == "cdn.galva.test" {
            finish(status: 200, contentType: "text/html", data: MockFixtures.testBundleHTML())
            return
        }

        // Event upload — record the body for assertions, then ack.
        if path.hasSuffix("/identities/batchCollect") {
            E2ERecorder.shared.recordUpload(readBody())
            finish(status: 200, json: "{}")
            return
        }

        // StoreKit transaction observer — ack (body unused on simulator).
        if path.hasSuffix("/v1/transactions/observe") {
            finish(status: 200, json: "{}")
            return
        }

        // SDK bootstrap.
        if path.hasSuffix("/sdk/initialize") {
            finish(status: 200, json: MockFixtures.initialize)
            return
        }

        // Resolve a specific communication (deep link or stream message).
        if method == "POST", path.contains("/identities/communications/"), path.hasSuffix("/resolve") {
            finish(status: 200, json: MockFixtures.resolve(for: Self.scenario))
            return
        }

        // In-app message poll.
        if method == "GET", path.hasSuffix("/identities/communications") {
            finish(status: 200, json: MockFixtures.poll(for: Self.scenario))
            return
        }

        // Catch-all for the WebView `apiFetch` proxy (e.g. /e2e/ping).
        finish(status: 200, json: #"{"ok":true}"#)
    }

    override func stopLoading() {}

    // MARK: Helpers

    /// Read the request body. URLSession moves bodies set via `httpBody` into
    /// `httpBodyStream` by the time a URLProtocol sees them, so read the stream.
    private func readBody() -> String {
        if let body = request.httpBody {
            return String(decoding: body, as: UTF8.self)
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func finish(status: Int, json: String) {
        finish(status: status, contentType: "application/json", data: Data(json.utf8))
    }

    private func finish(status: Int, contentType: String, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": contentType]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
