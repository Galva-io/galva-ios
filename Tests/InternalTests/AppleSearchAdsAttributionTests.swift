//
//  AppleSearchAdsAttributionTests.swift
//  GalvaTests
//
//  Covers Apple Search Ads attribution:
//    • outcome(status:body:) — the HTTP-status → action mapping (200 / 400 /
//      404 / 500) per Apple's docs.
//    • mapTraits — campaign fields → `$gv_asa_*`, type-preserving, skipping
//      missing/untracked keys.
//    • IdentityStore persistence — resolved flag + traits survive a reload and
//      are device-scoped.
//    • identify re-attaches the resolved traits, so a later login carries the
//      install's attribution.
//

import Foundation
@testable import Galva
import XCTest

final class AppleSearchAdsAttributionTests: XCTestCase {

    // MARK: - outcome(status:body:)

    func test_outcome_200_attributed_mapsTraits() {
        let body = Data(#"""
        {"attribution":true,"orgId":40669820,"campaignId":542370539,"keywordId":87675432,"conversionType":"Download"}
        """#.utf8)
        guard case .attributed(let traits) = AppleSearchAdsAttribution.outcome(status: 200, body: body) else {
            return XCTFail("expected .attributed")
        }
        XCTAssertEqual(traits["$gv_asa_orgId"], .int(40669820))
        XCTAssertEqual(traits["$gv_asa_campaignId"], .int(542370539))
        XCTAssertEqual(traits["$gv_asa_keywordId"], .int(87675432))
        XCTAssertEqual(traits["$gv_asa_conversionType"], .string("Download"))
        XCTAssertNil(traits["$gv_asa_attribution"], "the attribution flag itself is not a forwarded field")
    }

    func test_outcome_200_notAttributed() {
        XCTAssertEqual(
            AppleSearchAdsAttribution.outcome(status: 200, body: Data(#"{"attribution":false}"#.utf8)),
            .notAttributed
        )
    }

    func test_outcome_200_malformedBody_isNotAttributed() {
        XCTAssertEqual(
            AppleSearchAdsAttribution.outcome(status: 200, body: Data("not json".utf8)),
            .notAttributed
        )
    }

    func test_outcome_400_invalidToken() {
        XCTAssertEqual(AppleSearchAdsAttribution.outcome(status: 400, body: Data()), .invalidToken)
    }

    func test_outcome_404_retryShortly() {
        XCTAssertEqual(AppleSearchAdsAttribution.outcome(status: 404, body: Data()), .retryShortly)
    }

    func test_outcome_500_retryLater() {
        XCTAssertEqual(AppleSearchAdsAttribution.outcome(status: 500, body: Data()), .retryLater)
    }

    // MARK: - mapTraits

    func test_mapTraits_prefixesTrackedFields_preservesTypes_skipsTheRest() {
        let response: [String: AnyJSONValue] = [
            "attribution": .bool(true),
            "orgId": .int(40669820),
            "countryOrRegion": .string("US"),
            "supplyPlacement": .string("APPSTORE_SEARCH_RESULTS"),
            "adId": .int(542317136),
            "somethingElse": .string("ignored"),   // not tracked
        ]
        let traits = AppleSearchAdsAttribution.mapTraits(response)
        XCTAssertEqual(traits["$gv_asa_orgId"], .int(40669820))
        XCTAssertEqual(traits["$gv_asa_countryOrRegion"], .string("US"))
        XCTAssertEqual(traits["$gv_asa_supplyPlacement"], .string("APPSTORE_SEARCH_RESULTS"))
        XCTAssertEqual(traits["$gv_asa_adId"], .int(542317136))
        XCTAssertNil(traits["$gv_asa_somethingElse"], "untracked field must not be forwarded")
        XCTAssertNil(traits["$gv_asa_campaignId"], "absent field must not appear")
        XCTAssertNil(traits["$gv_asa_attribution"], "the flag is not a forwarded field")
    }
}

// MARK: - Persistence + identify integration

@GalvaActor
final class AppleSearchAdsIntegrationTests: XCTestCase {

    func test_persistence_resolvedAndTraits_surviveReload() async {
        let suite = "co.galva.test.asa.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("could not allocate UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = IdentityStore(defaults: defaults)
        XCTAssertFalse(store.appleSearchAdsResolved)
        XCTAssertTrue(store.appleSearchAdsTraits.isEmpty)

        store.setAppleSearchAds(resolved: true, traits: ["$gv_asa_keywordId": .int(87675432)])

        let reloaded = IdentityStore(defaults: defaults)
        XCTAssertTrue(reloaded.appleSearchAdsResolved)
        XCTAssertEqual(reloaded.appleSearchAdsTraits["$gv_asa_keywordId"], .int(87675432))
    }

    func test_resolvedTraits_reattachedOnIdentify() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // Simulate a prior install having resolved ASA attribution.
        harness.identity.setAppleSearchAds(resolved: true, traits: [
            "$gv_asa_keywordId": .int(87675432),
            "$gv_asa_conversionType": .string("Download"),
        ])

        await harness.consumer.reset()
        await harness.core.identify(userId: "asa_user", appAccountToken: nil, traits: nil)

        let traits = await harness.consumer.allMessages.compactMap(\.identifyTraits).first
        XCTAssertEqual(traits?["$gv_asa_keywordId"], .int(87675432),
                       "a later login must carry the install's resolved ASA attribution")
        XCTAssertEqual(traits?["$gv_asa_conversionType"], .string("Download"))
        // Device traits are still attached alongside.
        XCTAssertNotNil(traits?[BuiltInTraitKey.timezone])
    }
}
