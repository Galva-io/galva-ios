//
//  InitializationDataTests.swift
//  GalvaTests
//
//  Covers the dual-shape decoder on `InitializationData`, plus the
//  `BatchCollection` ms→s conversion.
//
//  Wire shape (server response):
//      {
//        "webviewVersions": [...],
//        "batchCollection": {...},
//        "appstore":  { "productIds": [...] },   // optional
//        "playstore": { "productIds": [...] }    // optional — iOS ignores
//      }
//
//  Cache shape (what we write to disk):
//      {
//        "webviewVersions": [...],
//        "batchCollection": {...},
//        "storekitProductIds": [...]
//      }
//
//  Both shapes must decode to the same Swift value.
//

import Foundation
@testable import Galva
import XCTest

final class InitializationDataTests: XCTestCase {

    // MARK: - Wire decoder (new flat appstore.productIds shape)

    func test_wire_readsAppstoreProductIds() throws {
        let json = #"""
        {
          "webviewVersions": ["1.0.0"],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "appstore":  { "productIds": ["com.app.pro.year", "com.app.pro.month"] },
          "playstore": { "productIds": ["com.app.pro.year.gp"] }
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        // Only the appstore branch is consumed — playstore is ignored.
        XCTAssertEqual(
            decoded.storekitProductIds,
            ["com.app.pro.year", "com.app.pro.month"]
        )
        XCTAssertEqual(decoded.webviewVersions, ["1.0.0"])
    }

    func test_wire_dedupesProductIds_preservingOrder() throws {
        // Defensive — the server shouldn't ship dupes, but we filter
        // them out so the StoreKit prefetcher doesn't fan out duplicate
        // `Product.products(for:)` lookups.
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "appstore": { "productIds": ["com.a", "com.b", "com.a", "com.c", "com.b"] }
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["com.a", "com.b", "com.c"])
    }

    func test_wire_filtersEmptyProductIds() throws {
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "appstore": { "productIds": ["", "com.real", ""] }
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["com.real"])
    }

    func test_wire_appstoreOptional_yieldsEmptyIds() throws {
        // `appstore` is optional in the OpenAPI spec. Apps with no
        // appstore-billed products receive a response without that block.
        let json = #"""
        {
          "webviewVersions": ["1.0.0"],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 }
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, [])
        XCTAssertEqual(decoded.webviewVersions, ["1.0.0"])
    }

    func test_wire_ignoresUnknownTopLevelFields() throws {
        // Forward-compat: server can add new top-level fields without
        // breaking decode — JSONDecoder ignores unknown keys.
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "appstore": { "productIds": ["com.app"] },
          "futureFeatureKey": { "anything": "ignored" }
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["com.app"])
    }

    // MARK: - Cache decoder

    func test_cache_acceptsFlatProductIdList() throws {
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

    func test_cache_flatListWinsOverWireAppstore() throws {
        // If both shapes are present (defensive — shouldn't happen on
        // either disk or wire), the flat list — which is the form WE
        // wrote — wins. The wire `appstore` branch is not consulted.
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "storekitProductIds": ["cached_id"],
          "appstore": { "productIds": ["wire_id"] }
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["cached_id"])
    }

    func test_cache_filtersEmptyEntries_onRead() throws {
        // Belt-and-suspenders against a tampered or corrupted cache file.
        let json = #"""
        {
          "webviewVersions": [],
          "batchCollection": { "flushSize": 50, "flushIntervalMs": 5000 },
          "storekitProductIds": ["", "com.real", ""]
        }
        """#
        let decoded = try JSONDecoder().decode(InitializationData.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.storekitProductIds, ["com.real"])
    }

    // MARK: - Encode round-trip (cache shape)

    func test_encode_writesFlatShape_neverWireShape() throws {
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
        XCTAssertNil(asJSON["appstore"],
                     "encoder must never emit the wire `appstore` block")
        XCTAssertNil(asJSON["playstore"],
                     "encoder must never emit a `playstore` block")
    }

    func test_encode_decode_roundTrips() throws {
        let original = InitializationData(
            webviewVersions: ["1.0.0", "1.0.1"],
            batchCollection: .init(flushSize: 50, flushIntervalMs: 5000),
            storekitProductIds: ["com.app.year", "com.app.month"]
        )
        let bytes = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InitializationData.self, from: bytes)
        XCTAssertEqual(decoded, original)
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
