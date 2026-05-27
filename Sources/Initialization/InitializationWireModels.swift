//
//  InitializationWireModels.swift
//  Galva
//
//  Wire-format models for POST /sdk/initialize.
//
//  Scope on iOS
//  ────────────
//  The iOS client only uses three pieces of the response:
//      • `webviewVersions`       — drives bundle prefetch + show fallback
//      • `batchCollection`       — server-tuned flush window for the queue
//      • Apple `productId`s      — fed into StoreKit prefetch so offer
//                                  pricing is ready before the WebView opens
//
//  We DELIBERATELY do not model the server's product / plan / platformSpec
//  shapes as Swift types. The server keeps full Plan / Product / cross-
//  platform billing metadata for backend reasons; the iOS client just
//  walks the raw JSON to pull `productId` strings out and discards
//  everything else. That keeps the SDK forward-compatible with any server
//  schema change short of renaming the path
//  `products[].plans[].platformSpecs.appstore.subscriptions[].productId`.
//
//  Cache format
//  ────────────
//  Cache writes use a flat shape — only what we'll actually read back:
//      {
//        "webviewVersions": [...],
//        "batchCollection": {...},
//        "storekitProductIds": [...]
//      }
//  The decoder accepts both the wire shape (nested `products`) and the
//  cache shape (flat `storekitProductIds`), so the same Swift type
//  round-trips through `/sdk/initialize` and the on-disk cache file.
//
//  Request:
//      { "bridgeProtocolVersion": "1.0" }
//

import Foundation

// MARK: - Request

struct InitializeRequest: Sendable, Codable, Hashable {
    let bridgeProtocolVersion: String
}

// MARK: - Response envelope (meta + data)

struct InitializeResponse: Sendable, Codable, Hashable {
    let meta: Meta?
    let data: InitializationData

    struct Meta: Sendable, Codable, Hashable {
        let requestId: String?
        let timestamp: Date?
        let total: Double?
        let nextCursor: String?
    }
}

// MARK: - Initialization data (the iOS-relevant slice)

struct InitializationData: Sendable, Codable, Hashable {

    /// Catalog of WebView HTML bundle versions the server considers
    /// renderable for this client. Most-recent last; the show flow uses
    /// the last entry as fallback when a resolve doesn't pin one.
    let webviewVersions: [String]

    /// Server-tuned batching window. Applied to the live MessageQueue on
    /// every successful refresh so server-side load management is genuinely
    /// remote-controlled.
    let batchCollection: BatchCollection

    /// Apple StoreKit product identifiers extracted from the server's
    /// product catalog. Fed into `StoreKit.Product.products(for:)` so
    /// offer pricing is ready before any in-app message renders.
    /// De-duped, ordered by first encounter.
    let storekitProductIds: [String]

    init(
        webviewVersions: [String],
        batchCollection: BatchCollection,
        storekitProductIds: [String]
    ) {
        self.webviewVersions = webviewVersions
        self.batchCollection = batchCollection
        self.storekitProductIds = storekitProductIds
    }

    struct BatchCollection: Sendable, Codable, Hashable {
        /// Number of pending messages that forces an immediate flush.
        let flushSize: Double
        /// Time-based flush interval, in milliseconds.
        let flushIntervalMs: Double

        /// `flushIntervalMs` converted to seconds for the queue's
        /// `TimeInterval` API.
        var flushInterval: TimeInterval { flushIntervalMs / 1000.0 }

        /// Integer view of `flushSize` (the wire type is `number`).
        var flushAtCount: Int { Int(flushSize) }
    }

    // MARK: Codable — dual-shape decoder

    private enum CodingKeys: String, CodingKey {
        case webviewVersions
        case batchCollection
        case products            // wire shape
        case storekitProductIds  // cache shape
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.webviewVersions = try c.decode([String].self, forKey: .webviewVersions)
        self.batchCollection = try c.decode(BatchCollection.self, forKey: .batchCollection)

        // Cache shape wins when present — it's the canonical form we
        // wrote ourselves and skips the walk over server-side product
        // metadata we don't care about.
        if let flat = try c.decodeIfPresent([String].self, forKey: .storekitProductIds) {
            self.storekitProductIds = flat
            return
        }

        // Wire shape: walk the raw `products` tree, pulling only
        // appstore productIds. Missing / malformed branches are skipped
        // silently — the server can add platforms / restructure plans
        // without breaking decode.
        let rawProducts = try c.decodeIfPresent([AnyJSONValue].self, forKey: .products) ?? []
        self.storekitProductIds = Self.extractAppleProductIds(from: rawProducts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(webviewVersions, forKey: .webviewVersions)
        try c.encode(batchCollection, forKey: .batchCollection)
        // Canonical cache form — flat productId list. We never re-emit
        // the nested `products` tree.
        try c.encode(storekitProductIds, forKey: .storekitProductIds)
    }

    // MARK: Wire extraction
    //
    // Walks `products[].plans[].platformSpecs.appstore.subscriptions[]`
    // pulling out `productId` strings. Tolerant of every branch being
    // missing or the wrong type — anything unexpected is silently
    // skipped, never thrown.

    static func extractAppleProductIds(from products: [AnyJSONValue]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for product in products {
            guard case .object(let productObj) = product,
                  case .array(let plans)? = productObj["plans"] else { continue }
            for plan in plans {
                guard case .object(let planObj) = plan,
                      case .object(let specs)? = planObj["platformSpecs"],
                      case .object(let appstore)? = specs["appstore"],
                      case .array(let subs)? = appstore["subscriptions"] else { continue }
                for sub in subs {
                    guard case .object(let subObj) = sub,
                          case .string(let pid)? = subObj["productId"],
                          !pid.isEmpty,
                          seen.insert(pid).inserted else { continue }
                    ordered.append(pid)
                }
            }
        }
        return ordered
    }
}
