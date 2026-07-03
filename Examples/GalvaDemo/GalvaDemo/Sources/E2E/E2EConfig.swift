//
//  E2EConfig.swift
//  GalvaDemo
//
//  Resolves the run mode from the process environment. UI tests launch the
//  app with `GALVA_E2E=1` + a `GALVA_E2E_SCENARIO`; everything else is a
//  manual run against the real `.development` backend.
//

import Foundation
import Galva

/// Selects which canned backend responses the in-process mock serves.
enum E2EScenario: String {
    /// Poll returns one in-app message → SwiftUI auto-display renders it.
    case showInAppMessage
    /// Same message as `showInAppMessage`, but presented through the UIKit
    /// `message.show(in:)` presenter (the path the React Native wrapper uses)
    /// instead of the SwiftUI auto-display modifier.
    case showInAppMessageUIKit
    /// Two distinct messages sharing bundle `1.0.0`. The first caches the
    /// bundle; the "Next message" control serves the second, which reuses the
    /// cached bundle and boots instantly — reproducing the cached-second-
    /// presentation safe-area race.
    case showInAppMessageTwice
    /// Poll returns nothing; only a deep link resolves a message.
    case deepLinkTarget
    /// Reproduces the real-world deep-link/poll race: the deep link's resolve
    /// is served with ~2s of simulated network latency, so a message polled
    /// via "Next message" lands squarely INSIDE the deep-link flight window.
    /// Without delivery deferral the polled message presents mid-flight and
    /// the two presentations collide.
    case deepLinkRace
    /// Poll returns nothing and resolve is invalid (quiet baseline).
    case noMessages
}

struct E2EConfig {
    let isE2E: Bool
    /// Whether the SDK is configured at all. `false` only in the performance
    /// baseline (`GALVA_PERF_BASELINE=1`) — a pure host shell with zero Galva
    /// involvement, so the perf suite can measure the SDK's footprint as a
    /// delta against it.
    let sdkEnabled: Bool
    let scenario: E2EScenario
    let environment: Galva.Environment
    let apiKey: String

    /// Hosts the mock URLProtocol claims. `https` is fine even without TLS —
    /// the protocol intercepts the load before any network/ATS evaluation.
    static let mockAPIBaseURL = URL(string: "https://api.galva.test")!       // swiftlint:disable:this force_unwrapping
    static let mockCDNBaseURL = URL(string: "https://cdn.galva.test")!       // swiftlint:disable:this force_unwrapping

    static func fromEnvironment() -> E2EConfig {
        let env = ProcessInfo.processInfo.environment

        // Performance baseline: don't touch Galva at all (no mock, no
        // configure). The perf suite compares this against SDK-on.
        if env["GALVA_PERF_BASELINE"] == "1" {
            return E2EConfig(
                isE2E: false,
                sdkEnabled: false,
                scenario: .noMessages,
                environment: .development,
                apiKey: ""
            )
        }

        if env["GALVA_E2E"] == "1" {
            let scenario = env["GALVA_E2E_SCENARIO"]
                .flatMap(E2EScenario.init(rawValue:)) ?? .showInAppMessage
            return E2EConfig(
                isE2E: true,
                sdkEnabled: true,
                scenario: scenario,
                environment: .custom(apiBaseURL: mockAPIBaseURL, webviewBundleCDN: mockCDNBaseURL),
                apiKey: "pk_e2e_demo"
            )
        }

        // Manual mode → real dev server. Supply a key via the `GALVA_DEV_API_KEY`
        // scheme env var (or an .xcconfig); falls back to an obvious placeholder.
        let devKey = env["GALVA_DEV_API_KEY"] ?? "pk_test_REPLACE_ME"
        return E2EConfig(
            isE2E: false,
            sdkEnabled: true,
            scenario: .noMessages,
            environment: .development,
            apiKey: devKey
        )
    }
}
