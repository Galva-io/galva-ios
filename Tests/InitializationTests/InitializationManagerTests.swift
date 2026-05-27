//
//  InitializationManagerTests.swift
//  GalvaTests
//
//  Verifies the SDK init flow:
//      • loadCached() surfaces a previously-persisted payload synchronously
//      • refresh() persists a fresh server response
//      • refresh() does NOT clobber the cached payload on network failure
//      • awaitInitialized() resolves once data lands (network or cache)
//

import Foundation
@testable import Galva
import XCTest

final class InitializationManagerTests: XCTestCase {

    private var tempFile: URL!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("galva-initmgr-\(UUID().uuidString).json")
        URLProtocolStub.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile)
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - loadCached

    func test_loadCached_surfaces_priorCachePayload() async throws {
        let cache = InitializationCache(fileURL: tempFile)
        try cache.save(InitFixtures.data(flushSize: 42))
        let manager = await makeManager(cache: cache)
        await manager.loadCached()
        let current = await manager.current
        XCTAssertEqual(current?.batchCollection.flushSize, 42)
    }

    func test_loadCached_leavesCurrentNil_whenNoCache() async {
        let cache = InitializationCache(fileURL: tempFile)
        let manager = await makeManager(cache: cache)
        await manager.loadCached()
        let current = await manager.current
        XCTAssertNil(current)
    }

    // MARK: - refresh

    func test_refresh_persistsResponse_andSetsCurrent() async throws {
        URLProtocolStub.handler = { request in
            let body = InitFixtures.responseEnvelope(flushSize: 77)
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
        let cache = InitializationCache(fileURL: tempFile)
        let session = URLProtocolStub.makeSession()
        let manager = await makeManager(cache: cache, session: session)
        await manager.refresh()

        let current = await manager.current
        XCTAssertEqual(current?.batchCollection.flushSize, 77)

        let reloaded = cache.load()
        XCTAssertEqual(reloaded?.batchCollection.flushSize, 77,
                       "successful refresh must persist to disk")
    }

    func test_refresh_keepsCachedValue_onNetworkFailure() async throws {
        let cache = InitializationCache(fileURL: tempFile)
        try cache.save(InitFixtures.data(flushSize: 11))

        URLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        let session = URLProtocolStub.makeSession()
        let manager = await makeManager(cache: cache, session: session)
        await manager.loadCached()
        await manager.refresh()

        let current = await manager.current
        XCTAssertEqual(current?.batchCollection.flushSize, 11,
                       "cached value must survive network failure")
    }

    // MARK: - awaitInitialized

    func test_awaitInitialized_resolvesImmediately_whenCachedAvailable() async throws {
        let cache = InitializationCache(fileURL: tempFile)
        try cache.save(InitFixtures.data(flushSize: 9))
        let manager = await makeManager(cache: cache)
        await manager.loadCached()
        let resolved = await manager.awaitInitialized()
        XCTAssertEqual(resolved?.batchCollection.flushSize, 9)
    }

    func test_awaitInitialized_resolvesAfterRefresh() async throws {
        URLProtocolStub.handler = { request in
            let body = InitFixtures.responseEnvelope(flushSize: 33)
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
        let cache = InitializationCache(fileURL: tempFile)
        let session = URLProtocolStub.makeSession()
        let manager = await makeManager(cache: cache, session: session)

        async let waiter = manager.awaitInitialized()
        await manager.refresh()
        let resolved = await waiter
        XCTAssertEqual(resolved?.batchCollection.flushSize, 33)
    }

    // MARK: - Helpers

    /// Build a manager inside the GalvaActor. Free function (not method)
    /// so self never crosses the actor boundary.
    private func makeManager(
        cache: InitializationCache?,
        session: URLSession = .shared
    ) async -> InitializationManager {
        await InitFixtures.makeManager(cache: cache, session: session)
    }
}

// MARK: - Nonisolated fixture builders for use inside @Sendable closures

private enum InitFixtures {

    @GalvaActor
    static func makeManager(
        cache: InitializationCache?,
        session: URLSession
    ) async -> InitializationManager {
        let client = APIClient(
            baseURL: URL(string: "https://api.galva.test")!,
            apiKey: "pk_test_abc",
            session: session,
            logger: SilentLogger()
        )
        return InitializationManager(
            client: client,
            cache: cache,
            logger: SilentLogger()
        )
    }

    static func data(flushSize: Double) -> InitializationData {
        InitializationData(
            webviewVersions: ["1.0.0"],
            batchCollection: .init(flushSize: flushSize, flushIntervalMs: 5000),
            storekitProductIds: []
        )
    }

    static func responseEnvelope(flushSize: Double) -> Data {
        let payload = data(flushSize: flushSize)
        let response = InitializeResponse(
            meta: .init(requestId: "rq_1", timestamp: Date(), total: nil, nextCursor: nil),
            data: payload
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        return try! encoder.encode(response)
    }
}
