//
//  Galva+Purchases.swift
//  Galva
//
//  Pluggable execution for purchases an in-app message requests.
//
//  By default the SDK drives an offer purchase itself through StoreKit 2
//  (`Product.purchase(options:)`, with the user's `appAccountToken` and any
//  Galva-signed promotional offer attached) and leaves the transaction
//  unfinished for your app. StoreKit does not broadcast a transaction made by
//  `Product.purchase(options:)` on `Transaction.updates` — it only resurfaces
//  there, as unfinished, on the next launch. A billing SDK that learns about
//  purchases from that listener (RevenueCat, an in-house observer, …)
//  therefore doesn't see a Galva-initiated purchase in the same session, and
//  the user's entitlement stays locked until they relaunch.
//
//  Install a `GalvaPurchaseController` to run those purchases through your
//  billing layer instead, so it records + finishes the transaction and
//  refreshes entitlements immediately:
//
//      struct BillingPurchaseController: GalvaPurchaseController {
//          @MainActor
//          func purchase(_ request: Galva.PurchaseRequest) async throws -> Galva.PurchaseResult {
//              let result = try await request.purchaseWithStoreKit()
//              guard case .success(.verified(let transaction)) = result else { … }
//              await MyBilling.shared.record(transaction)
//              await transaction.finish()
//              return .completed(transaction)
//          }
//      }
//
//      Galva.setPurchaseController(BillingPurchaseController())
//
//  RevenueCat apps don't write one — the `.revenueCat()` integration from the
//  `GalvaRevenueCat` package installs it (see `Galva+Integrations.swift`).
//

import Foundation

import StoreKit

// MARK: - GalvaPurchaseController

/// Executes the purchases Galva in-app messages request, in place of the
/// SDK's built-in StoreKit 2 flow. Install one with
/// ``Galva/setPurchaseController(_:)``.
///
/// Called on the main actor, once per purchase the user starts inside a
/// message. The bundle waits on the result, so return as soon as the purchase
/// settles.
public protocol GalvaPurchaseController: Sendable {

    /// Run `request` and report how it ended.
    ///
    /// - Returns: `.completed` with the verified transaction, `.pending` for
    ///   Ask to Buy / SCA, or `.cancelled` when the user dismissed the sheet.
    /// - Throws: A ``Galva/PurchaseError`` for failures the message should
    ///   handle specifically (unavailable product, ineligible offer, …).
    ///   `StoreKitError.userCancelled` counts as `.cancelled`; any other
    ///   error reaches the message as a generic purchase failure.
    @MainActor
    func purchase(_ request: Galva.PurchaseRequest) async throws -> Galva.PurchaseResult
}

// MARK: - Purchase types

public extension Galva {

    /// A promotional offer an in-app message asked to apply. Galva's backend
    /// signs it when the app has an In-App Purchase key in Galva: the JWS
    /// carries every claim (key id, nonce, product id, timestamp) the App
    /// Store needs to validate it — pass it to
    /// `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`. Without that
    /// key the offer comes unsigned, for a controller that has it signed
    /// elsewhere, as GalvaRevenueCat has RevenueCat sign it.
    struct PromotionalOffer: Sendable, Hashable {
        /// The offer identifier configured in App Store Connect.
        public let offerId: String
        /// JWS compact serialization (`header.payload.signature`) of the
        /// offer's signed claims; `nil` when Galva has no In-App Purchase key
        /// to sign it. ``PurchaseRequest/purchaseWithStoreKit()`` needs it.
        public let compactJWS: String?

        /// Build an offer by hand — for unit-testing a controller. Galva
        /// builds real offers itself.
        @_spi(Testing)
        public init(offerId: String, compactJWS: String?) {
            self.offerId = offerId
            self.compactJWS = compactJWS
        }
    }

    /// A purchase an in-app message asked for, handed to your
    /// ``GalvaPurchaseController``.
    struct PurchaseRequest: Sendable {
        /// App Store product identifier.
        public let productId: String
        /// Promotional offer to apply, if the message offers one.
        public let promotionalOffer: PromotionalOffer?
        /// The `appAccountToken` Galva attributes this user's purchases to —
        /// the same value as ``AppUser/appAccountToken``. Attach it to the
        /// purchase when your billing layer lets you.
        public let appAccountToken: UUID
        /// Id of the in-app message that requested the purchase.
        public let messageId: String

        /// The SDK's built-in StoreKit 2 flow, bound to this request.
        private let storeKitPurchase: @MainActor @Sendable () async throws -> Product.PurchaseResult

        /// Build a request by hand — for unit-testing a controller, with
        /// `storeKitPurchase` standing in for the built-in StoreKit flow.
        /// Galva builds real requests itself.
        @_spi(Testing)
        public init(
            productId: String,
            promotionalOffer: PromotionalOffer?,
            appAccountToken: UUID,
            messageId: String,
            storeKitPurchase: @escaping @MainActor @Sendable () async throws -> Product.PurchaseResult
        ) {
            self.productId = productId
            self.promotionalOffer = promotionalOffer
            self.appAccountToken = appAccountToken
            self.messageId = messageId
            self.storeKitPurchase = storeKitPurchase
        }

        /// Run Galva's built-in StoreKit 2 purchase for this request — the
        /// product is resolved from the SDK's warm cache when possible, and
        /// ``appAccountToken`` plus any ``promotionalOffer`` are attached.
        ///
        /// Returns StoreKit's raw result with the transaction **unfinished**,
        /// so you can hand it to your billing layer (e.g. a "record purchase"
        /// API) and finish it there. A cancelled Apple ID sign-in comes back
        /// as `.userCancelled` too, not as an error.
        ///
        /// A promotional offer needs Galva's signature here: for an unsigned
        /// one (``PromotionalOffer/compactJWS`` is `nil`) it throws
        /// ``Galva/PurchaseError/invalidOffer(_:)`` without starting a
        /// purchase.
        ///
        /// - Throws: ``Galva/PurchaseError``.
        @MainActor
        public func purchaseWithStoreKit() async throws -> Product.PurchaseResult {
            try await storeKitPurchase()
        }
    }

    /// How a purchase run by a ``GalvaPurchaseController`` ended.
    enum PurchaseResult: Sendable {
        /// The purchase succeeded. Pass the verified transaction.
        case completed(Transaction)
        /// Awaiting approval (Ask to Buy / Strong Customer Authentication).
        case pending
        /// The user dismissed the purchase sheet.
        case cancelled
    }

    /// Structured purchase failures a ``GalvaPurchaseController`` can throw.
    /// Each one maps onto an error code the in-app message handles
    /// specifically; throw ``failed(_:)`` for anything else.
    ///
    /// Galva may add cases in minor releases. If you switch on this error,
    /// add an `@unknown default` case.
    enum PurchaseError: Error, Sendable, Hashable {
        /// The App Store doesn't sell this product.
        case productUnavailable
        /// Purchases are restricted on this device.
        case purchaseNotAllowed
        /// The user isn't eligible for the promotional offer.
        case ineligibleForOffer
        /// The product isn't sold in the user's storefront.
        case notAvailableInStorefront
        /// The App Store rejected the promotional offer.
        case invalidOffer(String)
        /// The transaction's signature didn't verify.
        case verificationFailed(String)
        /// The App Store or billing backend was unreachable.
        case networkError(String)
        /// Any other failure.
        case failed(String)
    }

    /// Run purchases that in-app messages request through `controller`
    /// instead of the SDK's built-in StoreKit 2 flow. Pass `nil` to restore
    /// the built-in flow.
    ///
    /// Safe to call at any time, before or after `configure(...)`; it applies
    /// to the next purchase a message requests. Returns immediately. The last
    /// controller set wins — including one an integration installs (e.g.
    /// `.revenueCat()`), so don't combine the two.
    static func setPurchaseController(_ controller: (any GalvaPurchaseController)?) {
        PurchaseControllerRegistry.current = controller
        let type = controller.map { String(describing: Swift.type(of: $0)) }
        SDKCore.shared.submit {
            $0.logger.info(.purchases, "purchase controller set", metadata: [
                "controller": type ?? "<built-in StoreKit>",
            ])
        }
    }
}

// MARK: - Registry

/// Holds the installed controller. Lock-protected so `setPurchaseController`
/// can be called from any thread, independent of `configure(...)` ordering,
/// and read by the bridge at purchase time.
enum PurchaseControllerRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: (any GalvaPurchaseController)?

    static var current: (any GalvaPurchaseController)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            _current = newValue
            lock.unlock()
        }
    }
}
