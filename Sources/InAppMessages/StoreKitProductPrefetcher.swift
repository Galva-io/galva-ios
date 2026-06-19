//
//  StoreKitProductPrefetcher.swift
//  Galva
//
//  Warm cache for StoreKit 2 `Product` metadata so in-app message bundles
//  have localized pricing + display copy available the moment they boot.
//
//  Lifecycle
//      • SDKCore kicks off `prefetch(productIds:)` after every successful
//        `/sdk/initialize` refresh (the response carries the catalog of
//        Apple SKUs the server is willing to sell on this app).
//      • `currentSummary()` returns whatever we've fetched so far — never
//        blocks, never throws. Empty when StoreKit is offline or no
//        productIds have been requested yet.
//      • The WebView presenter snapshots `currentSummaryObject()` right
//        before loading the bundle; the factory serializes it and injects
//        `window.galvaProducts` via WKUserScript at `.atDocumentStart`.
//
//  Why not block show() on a fresh fetch?
//  ─────────────────────────────────────
//  StoreKit calls can stall for seconds on a poor network. The bundle
//  always renders something — for offer screens the bundle can show a
//  loading state if `window.galvaProducts[productId]` is missing, then
//  re-render when it appears. We keep show() fast at the cost of
//  occasionally rendering an empty product map on first launch.
//

import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(StoreKit)

@GalvaActor
final class StoreKitProductPrefetcher {

    private let logger: any GalvaLogger

    /// Last fetched product set, keyed by productId.
    private var byId: [String: Product] = [:]

    /// In-flight fetch task. Cancelled when a new prefetch comes in with
    /// a different productId set so we don't pile up duplicate StoreKit
    /// calls during init-storms.
    private var fetchTask: Task<Void, Never>?

    /// Most recently requested productId set — short-circuits redundant
    /// prefetch calls that arrive with an identical list.
    private var lastRequested: Set<String> = []

    init(logger: any GalvaLogger) {
        self.logger = logger
    }

    // MARK: - Public lifecycle

    /// Kick off a background StoreKit fetch for `productIds`. No-op when
    /// the id set hasn't changed. Errors are swallowed and logged — the
    /// bundle handles the resulting empty / partial product map.
    func prefetch(productIds: [String]) {
        let requested = Set(productIds)
        if requested.isEmpty {
            logger.debug(.configuration, "storekit prefetch skipped (empty)")
            return
        }
        if requested == lastRequested {
            logger.debug(.configuration, "storekit prefetch skipped (same ids)")
            return
        }
        lastRequested = requested

        fetchTask?.cancel()
        let logger = self.logger
        fetchTask = Task { @GalvaActor [weak self] in
            await self?.performFetch(productIds: Array(requested), logger: logger)
        }
    }

    private func performFetch(productIds: [String], logger: any GalvaLogger) async {
        do {
            let fetched = try await Product.products(for: productIds)
            // Preserve the request order for stable diagnostics.
            var byId: [String: Product] = [:]
            for product in fetched { byId[product.id] = product }
            self.byId = byId
            logger.info(.configuration, "storekit prefetch OK", metadata: [
                "requested": String(productIds.count),
                "received": String(fetched.count),
            ])
        } catch is CancellationError {
            // Superseded by a newer request — silent.
        } catch {
            logger.warning(.configuration, "storekit prefetch failed", error: error)
        }
    }

    // MARK: - Product accessor

    /// Look up a previously-fetched `Product` by SKU. Returns `nil` when
    /// nothing has been pre-fetched yet — callers should fall back to a
    /// live `Product.products(for:)` round-trip rather than treating the
    /// miss as a purchase failure.
    func currentProduct(productId: String) -> Product? {
        byId[productId]
    }

    // MARK: - Summary for WebView injection

    /// Product summary keyed by `productId`, as Sendable structured JSON
    /// values (`AnyJSONValue`) — ready to cross actors and be serialized at
    /// the `window.galvaProducts` injection boundary by the WebView factory.
    /// Empty when nothing has been fetched yet (the bundle handles an empty
    /// catalog). Returning structured values rather than a pre-encoded string
    /// keeps serialization in one place and makes it impossible for a caller
    /// to inject an arbitrary string.
    func currentSummaryObject() -> [String: AnyJSONValue] {
        var out: [String: AnyJSONValue] = [:]
        for (id, fields) in currentSummary() {
            out[id] = .object(AnyJSONValue.coercing(dictionary: fields))
        }
        return out
    }

    /// JSON-shaped summary keyed by `productId`. Each value is a flat
    /// object with the fields the bundle is likely to render: localized
    /// price + display copy, raw price + currency for custom formatting,
    /// subscription metadata when present.
    func currentSummary() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for (id, product) in byId {
            out[id] = Self.summarize(product)
        }
        return out
    }

    // MARK: - Product → JSON

    private static func summarize(_ product: Product) -> [String: Any] {
        var obj: [String: Any] = [
            "id": product.id,
            "displayName": product.displayName,
            "description": product.description,
            "displayPrice": product.displayPrice,
            "price": NSDecimalNumber(decimal: product.price).stringValue,
            "currencyCode": product.priceFormatStyle.currencyCode,
            "type": typeString(product.type),
            "isFamilyShareable": product.isFamilyShareable,
        ]
        if let sub = product.subscription {
            obj["subscription"] = subscriptionSummary(sub)
        }
        return obj
    }

    private static func subscriptionSummary(
        _ sub: Product.SubscriptionInfo
    ) -> [String: Any] {
        var obj: [String: Any] = [
            "subscriptionGroupID": sub.subscriptionGroupID,
            "subscriptionPeriod": periodSummary(sub.subscriptionPeriod),
        ]
        if let intro = sub.introductoryOffer {
            obj["introductoryOffer"] = offerSummary(intro)
        }
        if !sub.promotionalOffers.isEmpty {
            obj["promotionalOffers"] = sub.promotionalOffers.map(offerSummary)
        }
        return obj
    }

    private static func offerSummary(
        _ offer: Product.SubscriptionOffer
    ) -> [String: Any] {
        [
            "id": offer.id ?? NSNull(),
            "type": offerTypeString(offer.type),
            "paymentMode": paymentModeString(offer.paymentMode),
            "period": periodSummary(offer.period),
            "periodCount": offer.periodCount,
            "displayPrice": offer.displayPrice,
            "price": NSDecimalNumber(decimal: offer.price).stringValue,
        ]
    }

    private static func periodSummary(
        _ period: Product.SubscriptionPeriod
    ) -> [String: Any] {
        [
            "value": period.value,
            "unit": periodUnitString(period.unit),
        ]
    }

    // MARK: - Enum mappers (camelCase strings; stable for the wire)

    private static func typeString(_ type: Product.ProductType) -> String {
        switch type {
        case .consumable:    return "consumable"
        case .nonConsumable: return "nonConsumable"
        case .autoRenewable: return "autoRenewable"
        case .nonRenewable:  return "nonRenewable"
        default:             return "unknown"
        }
    }

    private static func periodUnitString(
        _ unit: Product.SubscriptionPeriod.Unit
    ) -> String {
        switch unit {
        case .day:   return "day"
        case .week:  return "week"
        case .month: return "month"
        case .year:  return "year"
        @unknown default: return "unknown"
        }
    }

    private static func offerTypeString(
        _ type: Product.SubscriptionOffer.OfferType
    ) -> String {
        switch type {
        case .introductory: return "introductory"
        case .promotional:  return "promotional"
        default:            return "unknown"
        }
    }

    private static func paymentModeString(
        _ mode: Product.SubscriptionOffer.PaymentMode
    ) -> String {
        switch mode {
        case .freeTrial:   return "freeTrial"
        case .payAsYouGo:  return "payAsYouGo"
        case .payUpFront:  return "payUpFront"
        default:           return "unknown"
        }
    }
}

#endif // canImport(StoreKit)
