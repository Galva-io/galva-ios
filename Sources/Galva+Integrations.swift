//
//  Galva+Integrations.swift
//  Galva
//
//  Integrations connect Galva to another SDK in the app (RevenueCat, …).
//  Each ships as its own package, so apps that don't use that SDK never fetch
//  it, and plugs in through `configure(…, integrations:)`:
//
//      import GalvaRevenueCat
//
//      Purchases.configure(withAPIKey: "appl_…")
//      Galva.configure(apiKey: "pk_your_app_id", integrations: [.revenueCat()])
//
//  Apps only pass the factories integration packages provide. Building an
//  integration takes the `GalvaIntegration` SPI:
//
//      @_spi(GalvaIntegration) import Galva
//
//      public extension Galva.Integration {
//          static func mySDK() -> Galva.Integration {
//              Galva.Integration(name: "mysdk", version: "1.0.0") { context in
//                  context.logger.info(.integration, "connected to MySDK")
//              }
//          }
//      }
//
//  Galva installs each integration once, after its own `configure(...)` has
//  finished, on a background task — an integration never delays startup and
//  may call any public Galva API from its install closure.
//

import Foundation

public extension Galva {

    /// Connects Galva to another SDK in your app. Get one from an integration
    /// package — e.g. `.revenueCat()` from `GalvaRevenueCat` — and pass it to
    /// `Galva.configure(apiKey:…, integrations:)`.
    struct Integration: Sendable {
        /// Short identifier, e.g. `"revenuecat"`.
        @_spi(GalvaIntegration)
        public let name: String
        /// Version of the package that provides the integration.
        @_spi(GalvaIntegration)
        public let version: String

        let install: @Sendable (IntegrationContext) async -> Void

        /// Build an integration. For integration packages; apps use the
        /// factories those packages provide.
        ///
        /// - Parameter install: Called once, off the main thread, after Galva
        ///   is configured. Long-running work (observing another SDK) should
        ///   start its own task and return.
        @_spi(GalvaIntegration)
        public init(
            name: String,
            version: String,
            install: @escaping @Sendable (IntegrationContext) async -> Void
        ) {
            self.name = name
            self.version = version
            self.install = install
        }
    }

    /// What Galva hands an integration when installing it.
    @_spi(GalvaIntegration)
    struct IntegrationContext: Sendable {
        /// Galva's logger. The app's configured `logLevel` and custom
        /// `GalvaLogger` apply — including one installed later with
        /// `Galva.setLogger(_:)`. Log under `.integration`.
        public let logger: any GalvaLogger

        /// Build a context by hand — for unit-testing an integration. Galva
        /// builds real contexts itself.
        @_spi(Testing)
        public init(logger: any GalvaLogger) {
            self.logger = logger
        }
    }
}
