//
//  AppleSearchAdsAttribution.swift
//  Galva
//
//  Apple Search Ads attribution via Apple's AdServices framework. On first
//  launch the SDK reads the install's attribution token
//  (`AAAttribution.attributionToken()`) and resolves it against
//  `https://api-adservices.apple.com/api/v1/`, then maps the campaign fields
//  to `$gv_asa_*` user traits.
//
//  This file is the **pure** surface — token acquisition, HTTP-status →
//  outcome mapping, and field → trait mapping — so it's unit-testable without
//  a network or a device. The orchestration (retry policy, persistence,
//  re-send on identify) lives in `SDKCore+AppleSearchAds.swift`.
//
//  Response contract (per Apple docs):
//    • 200 — success. `attribution=true` → a matching record (campaign fields
//            present); `attribution=false` → acknowledged, no match.
//    • 400 — the token is invalid.
//    • 404 — record not found yet. Tokens have a 24h TTL; Apple's guidance is
//            to retry up to 3× at 5s intervals.
//    • 500 — Apple Ads server temporarily unreachable; retry later.
//

import Foundation
#if canImport(AdServices)
import AdServices
#endif

enum AppleSearchAdsAttribution {

    /// Apple's AdServices attribution endpoint.
    static let endpoint = URL(string: "https://api-adservices.apple.com/api/v1/")! // galva-lint:disable reason="build-time literal"

    /// Campaign fields forwarded to Galva, each as `$gv_asa_<field>`.
    static let trackedFields = [
        "orgId", "campaignId", "conversionType", "claimType", "adGroupId",
        "countryOrRegion", "keywordId", "adId", "supplyPlacement",
    ]

    /// Per Apple's docs, a 404 means the record isn't available yet — retry up
    /// to 3 times, 5 seconds apart, before giving up (until the next launch).
    static let notFoundRetryLimit = 3
    static let notFoundRetryDelayNanos: UInt64 = 5_000_000_000

    /// The install's attribution token, or `nil` when AdServices is
    /// unavailable (older OS, simulator, non-Apple platform) or the framework
    /// can't currently produce one — in which case resolution is retried on a
    /// later launch.
    static func currentToken() -> String? {
        #if canImport(AdServices)
        if #available(iOS 14.3, macOS 11.1, tvOS 14.3, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }

    /// What the resolver should do with an AdServices HTTP response.
    enum Outcome: Equatable {
        /// 200 + `attribution=true` — campaign fields mapped to `$gv_asa_*`.
        case attributed([String: AnyJSONValue])
        /// 200 + `attribution=false` — acknowledged, no matching record.
        case notAttributed
        /// 400 — the token was rejected.
        case invalidToken
        /// 404 — not found yet; retry shortly (5s, up to the retry limit).
        case retryShortly
        /// 500 / unexpected — retry on a later launch.
        case retryLater
    }

    /// Map an AdServices HTTP `(status, body)` to an `Outcome`. Pure.
    static func outcome(status: Int, body: Data) -> Outcome {
        switch status {
        case 200:
            // A 200 always means "resolved". A malformed body is treated as
            // not-attributed rather than looping forever.
            guard let object = try? JSONDecoder().decode([String: AnyJSONValue].self, from: body) else {
                return .notAttributed
            }
            if case .bool(true)? = object["attribution"] {
                return .attributed(mapTraits(object))
            }
            return .notAttributed
        case 400:
            return .invalidToken
        case 404:
            return .retryShortly
        default:
            // 500 and any other unexpected status → retry on a later launch.
            return .retryLater
        }
    }

    /// Map an AdServices payload to `$gv_asa_*` traits, preserving each
    /// field's JSON type (numeric ids stay numbers, codes stay strings) and
    /// dropping fields the payload omits.
    static func mapTraits(_ response: [String: AnyJSONValue]) -> [String: AnyJSONValue] {
        var out: [String: AnyJSONValue] = [:]
        for field in trackedFields {
            guard let value = response[field], value != .null else { continue }
            out[BuiltInTraitKey.appleSearchAdsPrefix + field] = value
        }
        return out
    }
}
