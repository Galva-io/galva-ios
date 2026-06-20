//
//  SDKCore+AppleSearchAds.swift
//  Galva
//
//  Orchestration for Apple Search Ads attribution (the pure pieces live in
//  `AppleSearchAdsAttribution`). Kicked off from `configure()` when the
//  `.appleSearchAds` auto-track category is enabled.
//
//  Flow (one-shot per install):
//    1. Read the AdServices attribution token.
//    2. POST it to Apple; map the response to an `Outcome`.
//    3. On a 200 (attributed or not) persist the result so we never re-fetch;
//       on a 404 retry 5s × 3; on 400 / 500 / transport, bail and let the
//       next launch try again.
//    4. When attributed, persist the `$gv_asa_*` traits and emit an identify
//       so they reach the server immediately. `SDKCore.identify` re-attaches
//       the persisted traits on every subsequent identify, so a later login
//       carries the install's attribution.
//

import Foundation

extension SDKCore {

    /// Resolve Apple Search Ads attribution once per install. No-op when
    /// already resolved, opted out, unconfigured, or AdServices can't produce
    /// a token. Runs on the `GalvaActor`; the 5s 404-retry sleep suspends
    /// (never blocks) the actor.
    func resolveAppleSearchAdsIfNeeded() async {
        guard !isOptedOut else { return }
        guard let identity else { return }
        // One-shot: a prior launch already got a 200 from AdServices.
        guard !identity.appleSearchAdsResolved else { return }
        guard let token = AppleSearchAdsAttribution.currentToken() else {
            logger.debug(.configuration,
                         "ASA — no attribution token (AdServices unavailable); will retry next launch")
            return
        }

        var attempt = 0
        while true {
            let outcome: AppleSearchAdsAttribution.Outcome
            do {
                outcome = try await Self.performAttributionRequest(token: token)
            } catch {
                logger.debug(.configuration, "ASA — request failed; retry next launch", error: error)
                return
            }

            switch outcome {
            case .attributed(let traits):
                identity.setAppleSearchAds(resolved: true, traits: traits)
                logger.info(.configuration, "ASA — attributed", metadata: ["fields": String(traits.count)])
                // Send now for the current identity. Future identifies merge
                // the persisted traits in automatically (see SDKCore.identify).
                await identify(userId: nil, appAccountToken: nil, traits: nil)
                return

            case .notAttributed:
                // Resolved with no matching record — mark done so we don't
                // re-fetch, but there are no campaign traits to attach.
                identity.setAppleSearchAds(resolved: true, traits: [:])
                logger.info(.configuration, "ASA — no matching attribution record")
                return

            case .invalidToken:
                // The token was rejected. A fresh token next launch may work,
                // so don't mark resolved — just stop hammering this one.
                logger.warning(.configuration, "ASA — token rejected (400); retry next launch")
                return

            case .retryShortly:
                attempt += 1
                if attempt >= AppleSearchAdsAttribution.notFoundRetryLimit {
                    logger.debug(.configuration, "ASA — still 404 after \(attempt) attempts; retry next launch")
                    return
                }
                try? await Task.sleep(nanoseconds: AppleSearchAdsAttribution.notFoundRetryDelayNanos)
                continue

            case .retryLater:
                logger.debug(.configuration, "ASA — server unavailable (5xx); retry next launch")
                return
            }
        }
    }

    /// POST the attribution token to Apple and classify the response.
    /// `nonisolated` + uses `URLSession.shared` so it doesn't pin the actor
    /// across the network round-trip.
    private nonisolated static func performAttributionRequest(
        token: String
    ) async throws -> AppleSearchAdsAttribution.Outcome {
        var request = URLRequest(url: AppleSearchAdsAttribution.endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(token.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return AppleSearchAdsAttribution.outcome(status: http.statusCode, body: data)
    }
}
