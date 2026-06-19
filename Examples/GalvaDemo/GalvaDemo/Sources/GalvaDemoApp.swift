//
//  GalvaDemoApp.swift
//  GalvaDemo
//
//  Entry point for the Galva SDK end-to-end demo. In normal runs it points at
//  the real `.development` backend for hands-on testing. Under UI tests
//  (`GALVA_E2E=1`) it wipes prior state, installs the in-process mock
//  transport, and configures the SDK against `*.galva.test` so the whole
//  stack (configure → poll → resolve → bundle → WebView → bridge → deep link)
//  runs deterministically with no network.
//

import SwiftUI

@main
struct GalvaDemoApp: App {

    private let config: E2EConfig

    init() {
        // MUST run before any view calls `.galvaConfigure` — the mock
        // URLProtocol has to be registered before the SDK's first
        // `URLSession.shared` request fires at configure time.
        config = E2EBootstrap.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView(config: config)
        }
    }
}
