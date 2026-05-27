//
//  InitializationDataTests.swift
//  GalvaTests
//
//  Covers the dual-shape decoder + tolerant product-id walker on
//  `InitializationData`, plus the `BatchCollection` ms→s conversion.
//
//  The wire shape carries a deeply-nested product / plan / platformSpec
//  tree the iOS SDK doesn't model; the decoder walks the raw JSON and
//  pulls only `productId` strings out of
//  `products[].plans[].platformSpecs.appstore.subscriptions[]`. The cache
//  shape is a flat `storekitProductIds: [String]` list. Both must decode
//  to the same Swift value.
//

import Foundation
@testable import Galva
import XCTest

final class InitializationDataTests: XCTestCase {

    // MARK: - Wire decoder

    func test_wire_extractsProductIds_fromNestedTree() throws {
        let json = #"""
        {
          "webviewVersions": ["1.0.0"],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "products": [{
            "id": "prod_1",
            "name": "Pro",
            "type": "renewable",
            "status": "active",
            "plans": [{
              "id": "plan_year",
              "status": "active",
              "name": "Yearly",
              "platformSpecs": {
                "appstore": {
                  "subscriptions": [
                    { "id": "sub_a", "productId": "com.app.pro.year" }
                  ]
                },
                "playstore": { "basePlans": [{ "productId": "ignored_google_id" }] }
              }
            }, {
              "id": "plan_month",
              "platformSpecs": {
                "appstore": {
                  "subscriptions": [
                    { "productId": "com.app.pro.month" }
                  ]
                }
              }
            }]
          }]
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(
            decoded.storekitProductIds,
            ["com.app.pro.year", "com.app.pro.month"],
            "must extract only Apple appstore product IDs, in encounter order"
        )
        XCTAssertEqual(decoded.webviewVersions, ["1.0.0"])
    }

    func test_wire_dedupesProductIds_acrossPlansAndProducts() throws {
        let dup = "com.app.pro.year"
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "products": [
            {
              "id": "p1", "name": "Pro",
              "plans": [
                { "id": "a", "platformSpecs": { "appstore": { "subscriptions": [{ "productId": "\#(dup)" }] } } },
                { "id": "b", "platformSpecs": { "appstore": { "subscriptions": [{ "productId": "\#(dup)" }] } } }
              ]
            },
            {
              "id": "p2", "name": "Family",
              "plans": [
                { "id": "c", "platformSpecs": { "appstore": { "subscriptions": [{ "productId": "\#(dup)" }] } } }
              ]
            }
          ]
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, [dup])
    }

    func test_wire_tolerates_missingBranches_andUnknownFields() throws {
        // Half the tree is missing / has unexpected fields / wrong types.
        // The decoder must still succeed and just yield no productIds for
        // the bad branches.
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "products": [
            { "id": "no_plans", "name": "X" },
            { "id": "weird_plans", "name": "Y", "plans": "not_an_array" },
            { "id": "no_apple", "name": "Z", "plans": [
                { "id": "p", "platformSpecs": { "playstore": { "basePlans": [] } } }
            ]},
            { "id": "empty_apple", "name": "W", "plans": [
                { "id": "p", "platformSpecs": { "appstore": {} } }
            ]},
            { "id": "ok", "name": "OK", "futureField": 42, "plans": [
                { "id": "p", "platformSpecs": {
                    "appstore": { "subscriptions": [
                        { "productId": "" },
                        { "productId": "com.app.real" }
                    ]}
                }}
            ]}
          ]
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["com.app.real"],
                       "must skip malformed / empty / non-Apple branches without throwing")
    }

    func test_wire_emptyProducts_yieldsEmptyIdList() throws {
        let json = #"""
        {
          "webviewVersions": ["v"],
          "batchCollection": { "flushSize": 10, "flushIntervalMs": 1000 },
          "products": []
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, [])
    }

    // MARK: - Cache decoder

    func test_cache_acceptsFlatProductIdList() throws {
        // Cache writes flat shape; decoder must accept it without the
        // nested `products` tree.
        let json = #"""
        {
          "webviewVersions": ["1.0.0"],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "storekitProductIds": ["com.app.a", "com.app.b"]
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["com.app.a", "com.app.b"])
    }

    func test_cache_flatListWinsOverNestedProducts() throws {
        // If both shapes are present (defensive), the flat list — which
        // is the form we wrote ourselves — wins. The nested products
        // branch isn't even walked.
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "storekitProductIds": ["cached_id"],
          "products": [
            { "id": "p", "name": "P", "plans": [
                { "id": "x", "platformSpecs": { "appstore": { "subscriptions": [
                    { "productId": "wire_id" }
                ]}}}
            ]}
          ]
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["cached_id"])
    }

    // MARK: - Encode round-trip

    func test_encode_writesFlatShape() throws {
        let data = InitializationData(
            webviewVersions: ["v1"],
            batchCollection: .init(flushSize: 25, flushIntervalMs: 3000),
            storekitProductIds: ["com.app.a", "com.app.b"]
        )
        let bytes = try JSONEncoder().encode(data)
        let asJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        XCTAssertNotNil(asJSON["storekitProductIds"])
        XCTAssertNil(asJSON["products"], "encoder must never emit the nested wire shape")
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
}
