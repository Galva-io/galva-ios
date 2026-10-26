//
//  IntegrationSPITests.swift
//  GalvaTests
//
//  Pins the SPI integration packages build on, imported the way they import
//  Galva — `@_spi`, not `@testable` — so a symbol drifting back to internal
//  breaks here instead of in GalvaRevenueCat.
//

import Foundation
@_spi(GalvaIntegration) @_spi(Testing) import Galva
import XCTest
#if canImport(StoreKit)
import StoreKit
#endif

private struct NoLogger: GalvaLogger {
    func log(_ entry: Galva.LogEntry) {}
}

final class IntegrationSPITests: XCTestCase {

    func test_integrationPackageCanBuildAnIntegration() {
        let integration = Galva.Integration(name: "example", version: "1.2.3") { context in
            context.logger.info(.integration, "installed")
        }

        XCTAssertEqual(integration.name, "example")
        XCTAssertEqual(integration.version, "1.2.3")
    }

    func test_integrationPackageCanBuildAContextForItsTests() {
        let context = Galva.IntegrationContext(logger: NoLogger())

        XCTAssertTrue(context.logger is NoLogger)
    }

    #if canImport(StoreKit)
    @MainActor
    func test_controllerTestsCanBuildARequest() async throws {
        let request = Galva.PurchaseRequest(
            productId: "com.app.pro.year",
            promotionalOffer: Galva.PromotionalOffer(offerId: "winback_50", compactJWS: "h.p.s"),
            appAccountToken: UUID(),
            messageId: "msg-1",
            storeKitPurchase: { .userCancelled }
        )

        guard case .userCancelled = try await request.purchaseWithStoreKit() else {
            return XCTFail("expected the stubbed StoreKit result")
        }
    }
    #endif
}
