//
//  InitializationDataTests.swift
//  GalvaTests
//
//  Covers the convenience accessors on `InitializationData` that the SDK
//  relies on at runtime:
//      • `storekitProductIds` — feeds StoreKit `Product.products(for:)`
//      • `BatchCollection.flushInterval` / `flushAtCount` — wire `Double`
//        millisecond / float counts into the queue's `TimeInterval` / `Int`
//
//  Also exercises the loose Codable behaviour: server-side unknown fields
//  must round-trip through `extra` without breaking the decode.
//

import Foundation
@testable import Galva
import XCTest

final class InitializationDataTests: XCTestCase {

    // MARK: - storekitProductIds

    func test_storekitProductIds_returnsEmpty_whenNoProducts() {
        let data = InitializationData(
            webviewVersions: [],
            batchCollection: .init(flushSize: 50, flushIntervalMs: 5000),
            products: []
        )
        XCTAssertEqual(data.storekitProductIds, [])
    }

    func test_storekitProductIds_extractsAcrossProductsAndPlans() {
        let data = InitializationData(
            webviewVersions: [],
            batchCollection: .init(flushSize: 50, flushIntervalMs: 5000),
            products: [
                .init(id: "p1", name: "Pro", plans: [
                    plan(productId: "com.app.pro.month"),
                    plan(productId: "com.app.pro.year"),
                ]),
                .init(id: "p2", name: "Lite", plans: [
                    plan(productId: "com.app.lite.year"),
                ]),
            ]
        )
        XCTAssertEqual(
            data.storekitProductIds,
            ["com.app.pro.month", "com.app.pro.year", "com.app.lite.year"]
        )
    }

    func test_storekitProductIds_dedupesAcrossPlans() {
        let dup = "com.app.pro.year"
        let data = InitializationData(
            webviewVersions: [],
            batchCollection: .init(flushSize: 50, flushIntervalMs: 5000),
            products: [
                .init(id: "p1", name: "Pro", plans: [
                    plan(productId: dup),
                    plan(productId: dup),
                ]),
                .init(id: "p2", name: "Pro Family", plans: [
                    plan(productId: dup),
                ]),
            ]
        )
        XCTAssertEqual(data.storekitProductIds, [dup])
    }

    func test_storekitProductIds_skipsEmptyAndNil() {
        let data = InitializationData(
            webviewVersions: [],
            batchCollection: .init(flushSize: 50, flushIntervalMs: 5000),
            products: [
                .init(id: "p1", name: "Pro", plans: [
                    .init(id: "plan_a", name: nil, platformSpecs: .init(
                        appstore: .init(subscriptions: [
                            .init(productId: nil, id: "sub_1"),
                            .init(productId: "", id: "sub_2"),
                            .init(productId: "com.app.pro", id: "sub_3"),
                        ])
                    )),
                ]),
            ]
        )
        XCTAssertEqual(data.storekitProductIds, ["com.app.pro"])
    }

    // MARK: - BatchCollection conversions

    func test_batchCollection_convertsMillisecondsToSeconds() {
        let bc = InitializationData.BatchCollection(flushSize: 30, flushIntervalMs: 4500)
        XCTAssertEqual(bc.flushInterval, 4.5, accuracy: 0.0001)
        XCTAssertEqual(bc.flushAtCount, 30)
    }

    func test_batchCollection_truncatesFlushSizeToInt() {
        let bc = InitializationData.BatchCollection(flushSize: 25.9, flushIntervalMs: 1000)
        XCTAssertEqual(bc.flushAtCount, 25, "Double should truncate, not round")
    }

    // MARK: - Loose Codable

    func test_decode_acceptsUnknownProductFields() throws {
        // Server adds a future field we don't know about — decode must
        // succeed and capture the extra into `Product.extra`.
        let json = #"""
        {
          "webviewVersions": ["1.0.0"],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "products": [{
            "id": "prod_1",
            "name": "Pro",
            "plans": [],
            "type": "renewable",
            "status": "active",
            "futureField": { "nested": "value" }
          }]
        }
        """#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(InitializationData.self, from: data)
        XCTAssertEqual(decoded.products.count, 1)
        XCTAssertEqual(decoded.products[0].id, "prod_1")
        // The unknown fields should appear in `extra` so diagnostics + future
        // SDK versions can lift them without a wire-format change.
        XCTAssertNotNil(decoded.products[0].extra)
        XCTAssertNotNil(decoded.products[0].extra?["futureField"])
    }

    func test_decode_acceptsUnknownPlanPlatformSpecs() throws {
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "products": [{
            "id": "p", "name": "P",
            "plans": [{
              "id": "plan_1",
              "platformSpecs": {
                "appstore": { "subscriptions": [{ "productId": "com.app.pro" }] },
                "playstore": { "basePlans": [{ "newKey": "ok" }] },
                "stripe": { "anything": true }
              }
            }]
          }]
        }
        """#
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(InitializationData.self, from: data)
        let specs = try XCTUnwrap(decoded.products[0].plans?.first?.platformSpecs)
        XCTAssertEqual(specs.appstore?.subscriptions.first?.productId, "com.app.pro")
        // Non-Apple specs should round-trip through `other` instead of
        // exploding on schema drift.
        XCTAssertNotNil(specs.other?["playstore"])
        XCTAssertNotNil(specs.other?["stripe"])
    }

    // MARK: - Helpers

    private func plan(productId: String) -> InitializationData.Plan {
        .init(
            id: "plan_\(UUID().uuidString.prefix(6))",
            name: "Plan",
            platformSpecs: .init(
                appstore: .init(subscriptions: [
                    .init(productId: productId, id: nil),
                ])
            )
        )
    }
}
