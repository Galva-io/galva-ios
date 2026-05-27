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
//      • `appstore.productIds`   — fed into StoreKit prefetch so offer
//                                  pricing is ready before the WebView opens
//
//  The server may also return `playstore.productIds` for Android clients;
//  the iOS SDK ignores that branch entirely.
//
//  Cache format
//  ────────────
//  Cache writes use a flat shape — only what we'll actually read back:
//      {
//        "webviewVersions": [...],
//        "batchCollection": {...},
//        "storekitProductIds": [...]
//      }
//  The decoder accepts both the wire shape (`appstore.productIds`) and the
//  cache shape (`storekitProductIds`), so the same Swift type round-trips
//  through `/sdk/initialize` and the on-disk cache file.
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

    /// Apple StoreKit product identifiers. Fed into
    /// `StoreKit.Product.products(for:)` so offer pricing is ready before
    /// any in-app message renders. Empty when the server doesn't include
    /// an `appstore` block in the response (the field is optional in the
    /// `/sdk/initialize` spec).
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
        case appstore            // wire shape: { productIds: [String] }
        case storekitProductIds  // cache shape: [String] (we wrote this)
    }

    /// Wire shape for the `appstore` (and `playstore`, ignored on iOS)
    /// block — `{ productIds: [String] }`. Stays a private nested type
    /// because nothing outside the decoder cares.
    private struct PlatformProductIds: Decodable {
        let productIds: [String]
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.webviewVersions = try c.decode([String].self, forKey: .webviewVersions)
        self.batchCollection = try c.decode(BatchCollection.self, forKey: .batchCollection)

        // Cache shape wins when present — it's the canonical form we
        // wrote ourselves and doesn't need wire-format mapping.
        if let flat = try c.decodeIfPresent([String].self, forKey: .storekitProductIds) {
            // Defensive: drop empty entries the server should never send,
            // matching the cache-write contract.
            self.storekitProductIds = flat.filter { !$0.isEmpty }
            return
        }

        // Wire shape: pull straight from `appstore.productIds`. The block
        // is optional in the OpenAPI spec — apps with no appstore-billed
        // products will simply receive no Apple SKUs.
        if let appstore = try c.decodeIfPresent(
            PlatformProductIds.self, forKey: .appstore
        ) {
            // Filter empty strings + dedupe while preserving order so the
            // StoreKit prefetcher never asks Apple about an empty product
            // id and the seen-set in the prefetcher dedupes naturally.
            var seen: Set<String> = []
            var ordered: [String] = []
            for id in appstore.productIds where !id.isEmpty && seen.insert(id).inserted {
                ordered.append(id)
            }
            self.storekitProductIds = ordered
            return
        }

        self.storekitProductIds = []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(webviewVersions, forKey: .webviewVersions)
        try c.encode(batchCollection, forKey: .batchCollection)
        // Canonical cache form — flat productId list. We never re-emit
        // the wire `appstore` / `playstore` blocks.
        try c.encode(storekitProductIds, forKey: .storekitProductIds)
    }
}
