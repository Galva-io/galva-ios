//
//  StoreKitProductPrefetcherTests.swift
//  GalvaTests
//
//  Pins the prefetcher's retry contract: a failed StoreKit fetch (offline
//  launch) must not count as done, or every later prefetch with the same ids
//  is skipped and `window.galvaProducts` stays empty for the process. A
//  successful or in-flight fetch still short-circuits a repeat. Driven
//  through the injectable product loader; a real `Product` can't be built
//  here, so the stub answers with an error or no products.
//

import Foundation
@testable import Galva
import XCTest

import StoreKit

/// Stands in for `Product.products(for:)`: records each call, throws a
/// network error for the first `failures` calls and for any id in
/// `failingIds`, and otherwise answers with no products.
private actor ProductLoaderStub {
    private(set) var calls: [[String]] = []
    private var failures: Int
    private let failingIds: Set<String>

    init(failures: Int = 0, failingIds: Set<String> = []) {
        self.failures = failures
        self.failingIds = failingIds
    }

    func load(_ ids: [String]) throws -> [Product] {
        calls.append(ids.sorted())
        if failures > 0 || !failingIds.isDisjoint(with: ids) {
            failures = max(failures - 1, 0)
            throw StoreKitError.networkError(URLError(.notConnectedToInternet))
        }
        return []
    }

    func callCount(for ids: [String]) -> Int {
        calls.filter { $0 == ids.sorted() }.count
    }
}

@GalvaActor
final class StoreKitProductPrefetcherTests: XCTestCase {

    private let ids = ["com.app.pro.month", "com.app.pro.year"]

    private func makePrefetcher(_ stub: ProductLoaderStub) -> StoreKitProductPrefetcher {
        StoreKitProductPrefetcher(logger: SilentLogger(), loadProducts: { try await stub.load($0) })
    }

    func test_failedFetch_isRetriedByTheNextPrefetchWithTheSameIds() async {
        // Offline launch: the cached-ids prefetch fails, then the
        // /sdk/initialize refresh asks for the same ids again.
        let stub = ProductLoaderStub(failures: 1)
        let prefetcher = makePrefetcher(stub)

        prefetcher.prefetch(productIds: ids)
        await prefetcher.fetchTask?.value
        prefetcher.prefetch(productIds: ids)
        await prefetcher.fetchTask?.value

        let calls = await stub.calls.count
        XCTAssertEqual(calls, 2, "a failed fetch must not block a retry with the same ids")
    }

    func test_successfulFetch_skipsARepeatWithTheSameIds() async {
        let stub = ProductLoaderStub()
        let prefetcher = makePrefetcher(stub)

        prefetcher.prefetch(productIds: ids)
        await prefetcher.fetchTask?.value
        prefetcher.prefetch(productIds: ids.reversed())
        await prefetcher.fetchTask?.value

        let calls = await stub.calls.count
        XCTAssertEqual(calls, 1)
    }

    func test_inFlightFetch_skipsARepeatWithTheSameIds() async {
        // Cached + refreshed ids arriving back to back at launch.
        let stub = ProductLoaderStub(failures: 1)
        let prefetcher = makePrefetcher(stub)

        prefetcher.prefetch(productIds: ids)
        prefetcher.prefetch(productIds: ids)
        await prefetcher.fetchTask?.value

        let calls = await stub.calls.count
        XCTAssertEqual(calls, 1)
    }

    func test_supersededFailure_keepsTheNewerIds() async {
        // A superseded fetch that fails late (StoreKit ignores cancellation)
        // must not make the newer, successful ids fetch again.
        let stale = ["com.app.old"]
        let stub = ProductLoaderStub(failingIds: Set(stale))
        let prefetcher = makePrefetcher(stub)

        prefetcher.prefetch(productIds: stale)
        let staleTask = prefetcher.fetchTask
        prefetcher.prefetch(productIds: ids)
        await staleTask?.value
        await prefetcher.fetchTask?.value

        prefetcher.prefetch(productIds: ids)
        await prefetcher.fetchTask?.value

        let calls = await stub.callCount(for: ids)
        XCTAssertEqual(calls, 1)
    }
}
