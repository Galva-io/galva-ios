//
//  InitializationCacheTests.swift
//  GalvaTests
//
//  Verifies the disk-backed cache round-trips an InitializationData
//  payload, handles missing files cleanly, and rejects malformed cached
//  bytes (returns nil so the caller falls back to fresh network data).
//

import Foundation
@testable import Galva
import XCTest

final class InitializationCacheTests: XCTestCase {

    private var tempFile: URL!
    private var cache: InitializationCache!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("galva-init-test-\(UUID().uuidString).json")
        cache = InitializationCache(fileURL: tempFile)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile)
        super.tearDown()
    }

    func test_load_returnsNil_whenNoFileExists() {
        XCTAssertNil(cache.load())
    }

    func test_save_then_load_roundTrips() throws {
        let data = sampleInit()
        try cache.save(data)
        let loaded = cache.load()
        XCTAssertEqual(loaded, data)
    }

    func test_load_returnsNil_whenFileContainsGarbage() throws {
        try "this is not json".data(using: .utf8)!.write(to: tempFile)
        XCTAssertNil(cache.load())
    }

    func test_save_overwritesPreviousContent() throws {
        try cache.save(sampleInit())
        let updated = InitializationData(
            webviewVersions: ["9.9.9"],
            batchCollection: .init(flushSize: 1, flushIntervalMs: 1),
            products: []
        )
        try cache.save(updated)
        XCTAssertEqual(cache.load(), updated)
    }

    func test_clear_removesPersistedFile() throws {
        try cache.save(sampleInit())
        try cache.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
        XCTAssertNil(cache.load())
    }

    // MARK: - Fixtures

    private func sampleInit() -> InitializationData {
        InitializationData(
            webviewVersions: ["1.0.0", "1.0.1"],
            batchCollection: .init(flushSize: 50, flushIntervalMs: 5000),
            products: [
                .init(
                    id: "prod_1",
                    name: "Pro",
                    plans: [
                        .init(
                            id: "plan_yearly",
                            name: "Yearly",
                            platformSpecs: .init(
                                appstore: .init(subscriptions: [
                                    .init(productId: "com.acme.pro.yearly", id: "sub_1")
                                ])
                            )
                        )
                    ]
                )
            ]
        )
    }
}
