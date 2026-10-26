//
//  E2EBootstrap.swift
//  GalvaDemo
//
//  One-shot startup hook for UI-test runs: reset prior SDK state (so each
//  test starts anonymous with an empty bundle cache), select the mock
//  scenario, and register the in-process mock transport — all before the SDK
//  is configured.
//

import Foundation

enum E2EBootstrap {

    /// Resolve the run config; in E2E mode also reset state + install the mock.
    /// Returns the config the root view should configure the SDK with.
    static func runIfNeeded() -> E2EConfig {
        let config = E2EConfig.fromEnvironment()
        guard config.isE2E else { return config }

        resetState()
        GalvaMockURLProtocol.scenario = config.scenario
        URLProtocol.registerClass(GalvaMockURLProtocol.self)
        return config
    }

    /// Wipe the SDK state tests depend on: identity, opt-out and session state
    /// (UserDefaults) and the web-view bundle cache (`<Caches>/galva/`). The
    /// queue databases and init cache in `<Application Support>/Galva/` are
    /// kept.
    private static func resetState() {
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("galva", isDirectory: true)
        if let caches {
            try? FileManager.default.removeItem(at: caches)
        }
        E2ERecorder.shared.reset()
    }
}
