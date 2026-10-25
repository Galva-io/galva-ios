//
//  PurchaseControllerTests.swift
//  GalvaTests
//
//  Pins the `GalvaPurchaseController` seam: a host-installed controller
//  receives the parsed request, its results encode to the same
//  `requestPurchase` wire shape as the built-in StoreKit path, and its
//  failures map onto the structured `BridgeError` codes the bundle switches
//  on. `.completed` needs a real `StoreKit.Transaction`, so it's covered by
//  sandbox / device testing rather than here.
//

import Foundation
@_spi(Testing) @testable import Galva
import XCTest

#if canImport(StoreKit)
import StoreKit

@MainActor
private final class StubController: GalvaPurchaseController {
    private(set) var requests: [Galva.PurchaseRequest] = []
    private let respond: @MainActor (Galva.PurchaseRequest) async throws -> Galva.PurchaseResult

    init(_ respond: @escaping @MainActor (Galva.PurchaseRequest) async throws -> Galva.PurchaseResult) {
        self.respond = respond
    }

    func purchase(_ request: Galva.PurchaseRequest) async throws -> Galva.PurchaseResult {
        requests.append(request)
        return try await respond(request)
    }
}

private struct ForeignError: Error {}

@MainActor
final class PurchaseControllerTests: XCTestCase {

    private let token = UUID(uuidString: "b1fe821d-5597-4abc-87b6-1f9647cffd6e")!

    override func tearDown() {
        PurchaseControllerRegistry.current = nil
        super.tearDown()
    }

    private func makeRequest(
        promotionalOffer: Galva.PromotionalOffer? = nil,
        storeKitPurchase: @escaping @MainActor @Sendable () async throws -> Product.PurchaseResult = {
            throw Galva.PurchaseError.failed("built-in flow not expected")
        }
    ) -> Galva.PurchaseRequest {
        Galva.PurchaseRequest(
            productId: "com.app.pro.year",
            promotionalOffer: promotionalOffer,
            appAccountToken: token,
            messageId: "msg-1",
            storeKitPurchase: storeKitPurchase
        )
    }

    // MARK: - Dispatch

    func test_run_handsControllerTheParsedRequest() async {
        let offer = Galva.PromotionalOffer(offerId: "winback_50", compactJWS: "h.p.s")
        let controller = StubController { _ in .cancelled }

        _ = await PurchaseBridgeCodec.run(
            makeRequest(promotionalOffer: offer),
            with: controller,
            logger: SilentLogger()
        )

        XCTAssertEqual(controller.requests.count, 1)
        let request = controller.requests[0]
        XCTAssertEqual(request.productId, "com.app.pro.year")
        XCTAssertEqual(request.promotionalOffer, offer)
        XCTAssertEqual(request.appAccountToken, token)
        XCTAssertEqual(request.messageId, "msg-1")
    }

    func test_run_cancelled_encodesLikeBuiltInPath() async {
        let result = await PurchaseBridgeCodec.run(
            makeRequest(), with: StubController { _ in .cancelled }, logger: SilentLogger()
        )
        XCTAssertEqual(result, .success(.object(["outcome": .string("cancelled")])))
    }

    func test_run_pending_encodesLikeBuiltInPath() async {
        let result = await PurchaseBridgeCodec.run(
            makeRequest(), with: StubController { _ in .pending }, logger: SilentLogger()
        )
        XCTAssertEqual(result, .success(.object(["outcome": .string("pending")])))
    }

    func test_run_purchaseErrors_mapToBridgeCodes() async {
        let cases: [(Galva.PurchaseError, BridgeError.Code)] = [
            (.productUnavailable, .productUnavailable),
            (.purchaseNotAllowed, .purchaseNotAllowed),
            (.ineligibleForOffer, .ineligibleForOffer),
            (.notAvailableInStorefront, .notAvailableInStorefront),
            (.invalidOffer("invalidOfferSignature"), .invalidOffer),
            (.verificationFailed("bad sig"), .verificationFailed),
            (.networkError("offline"), .networkError),
            (.failed("boom"), .purchaseFailed),
        ]
        for (thrown, expected) in cases {
            let result = await PurchaseBridgeCodec.run(
                makeRequest(), with: StubController { _ in throw thrown }, logger: SilentLogger()
            )
            guard case .failure(let error) = result else {
                return XCTFail("expected failure for \(thrown)")
            }
            XCTAssertEqual(error.code, expected, "\(thrown)")
        }
    }

    func test_run_nonGalvaError_mapsToPurchaseFailed() async {
        let result = await PurchaseBridgeCodec.run(
            makeRequest(), with: StubController { _ in throw ForeignError() }, logger: SilentLogger()
        )
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .purchaseFailed)
    }

    func test_run_controllerFallingBackToStoreKit_propagatesBuiltInFailure() async {
        // A controller that delegates to the built-in flow (e.g. for a
        // Galva-signed offer its billing SDK can't apply) surfaces the
        // built-in failure with the same bridge code.
        let request = makeRequest(storeKitPurchase: {
            throw StoreKitPurchaser.Failure.ineligibleForOffer.publicError
        })
        let controller = StubController { request in
            _ = try await request.purchaseWithStoreKit()
            return .cancelled
        }

        let result = await PurchaseBridgeCodec.run(request, with: controller, logger: SilentLogger())

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error.code, .ineligibleForOffer)
    }

    // MARK: - Built-in failure mapping (unchanged wire codes)

    func test_builtInFailures_keepTheirBridgeCodes() {
        let cases: [(StoreKitPurchaser.Failure, BridgeError.Code)] = [
            (.productUnavailable, .productUnavailable),
            (.purchaseNotAllowed, .purchaseNotAllowed),
            (.ineligibleForOffer, .ineligibleForOffer),
            (.invalidOffer(detail: "missingOfferParameters"), .invalidOffer),
            (.verificationFailed(detail: "bad sig"), .verificationFailed),
            (.notAvailableInStorefront, .notAvailableInStorefront),
            (.networkError(underlying: URLError(.notConnectedToInternet)), .networkError),
            (.invalidPayload(detail: "invalidQuantity"), .invalidPayload),
            (.underlying(ForeignError()), .purchaseFailed),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(PurchaseBridgeCodec.bridgeError(for: failure).code, expected, "\(failure)")
        }
    }

    // MARK: - Registry

    func test_setPurchaseController_installsAndClears() {
        XCTAssertNil(PurchaseControllerRegistry.current)

        Galva.setPurchaseController(StubController { _ in .cancelled })
        XCTAssertTrue(PurchaseControllerRegistry.current is StubController)

        Galva.setPurchaseController(nil)
        XCTAssertNil(PurchaseControllerRegistry.current)
    }
}

#endif // canImport(StoreKit)
