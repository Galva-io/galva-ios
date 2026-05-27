//
//  WebViewBundleCacheTests.swift
//  GalvaTests
//
//  Verifies:
//      • bundleURL(for:) downloads + persists when no local copy exists
//      • a second call for the same version is served from disk (no extra
//        network)
//      • concurrent calls for the same version coalesce into one request
//

import Foundation
@testable import Galva
import XCTest

final class WebViewBundleCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("galva-bundle-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        URLProtocolStub.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        URLProtocolStub.reset()
        super.tearDown()
    }

    func test_bundleURL_downloads_andPersists_onCacheMiss() async throws {
        let html = "<!doctype html><title>test</title>"
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             Data(html.utf8))
        }
        let cache = try makeCache()
        let url = try await cache.bundleURL(for: "1.0.0")
        XCTAssertEqual(url.lastPathComponent, "1.0.0.html")
        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(persisted, html)
        XCTAssertEqual(URLProtocolStub.requests.count, 1)
    }

    func test_bundleURL_servesFromDisk_onCacheHit() async throws {
        let counter = Counter()
        URLProtocolStub.handler = { request in
            counter.increment()
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200),
                    Data("once".utf8))
        }
        let cache = try makeCache()
        _ = try await cache.bundleURL(for: "2.0.0")
        _ = try await cache.bundleURL(for: "2.0.0")
        _ = try await cache.bundleURL(for: "2.0.0")
        XCTAssertEqual(counter.value, 1, "second + third calls must hit the disk cache")
    }

    func test_bundleURL_throws_when404_andNoCache() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 404), Data())
        }
        let cache = try makeCache()
        await XCTAssertThrowsErrorAsync(try await cache.bundleURL(for: "9.9.9"))
    }

    func test_bundleURL_coalescesConcurrentDownloads() async throws {
        let counter = Counter()
        URLProtocolStub.handler = { request in
            counter.increment()
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200),
                    Data("payload".utf8))
        }
        let cache = try makeCache()
        async let a = cache.bundleURL(for: "3.0.0")
        async let b = cache.bundleURL(for: "3.0.0")
        async let c = cache.bundleURL(for: "3.0.0")
        _ = try await (a, b, c)
        XCTAssertEqual(counter.value, 1, "concurrent requests must coalesce")
    }

    // MARK: - Helpers

    private func makeCache() throws -> WebViewBundleCache {
        let session = URLProtocolStub.makeSession()
        let client = APIClient(
            baseURL: URL(string: "https://api.galva.test")!,
            apiKey: "pk_test",
            session: session,
            logger: SilentLogger()
        )
        return try WebViewBundleCache(
            directoryURL: tempDir,
            client: client,
            cdnBaseURL: URL(string: "https://webview.galva.test")!,
            logger: SilentLogger()
        )
    }
}

// MARK: - Sendable counter for @Sendable URLProtocolStub closures

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}

// MARK: - tiny async-throws assertion helper

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected to throw", file: file, line: line)
    } catch {
        // expected
    }
}
