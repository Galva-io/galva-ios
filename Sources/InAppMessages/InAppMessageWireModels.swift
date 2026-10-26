//
//  InAppMessageWireModels.swift
//  Galva
//
//  INTERNAL wire-format models for:
//      • GET  /identities/communications?channelType=in-app   (list)
//      • POST /identities/communications/{id}/resolve         (resolve)
//
//  Integrators don't touch these — they interact with the public
//  `InAppMessages.Message` envelope. Splitting the wire surface from the
//  public model keeps server-side schema evolution (new component types,
//  new payload fields) off the public ABI.
//

import Foundation

// MARK: - List response

/// `GET /identities/communications` payload. We always pass
/// `channelType=in-app` from the SDK, so every item's `type` is one of the
/// in-app variants (currently `trial-rescue-in-app`).
struct CommunicationListResponse: Sendable, Codable, Hashable {
    let data: [CommunicationItem]
}

/// One row in the communication list. Drives the public `InAppMessages.Message`.
struct CommunicationItem: Sendable, Codable, Hashable {
    let id: UUID
//    let type: CommunicationType
    /// Workflow the communication came from, as the server's raw value
    /// (`"trial-rescue"`, …). Nullable on the wire — the server returns null
    /// for broadcast / manual sends.
    ///
    /// Deliberately a plain string, not a closed enum: the server adds
    /// workflow types over time, and an enum would fail to decode an unknown
    /// value — taking the whole communication list down with it. The public
    /// `InAppMessages.WorkflowType` wraps whatever arrives.
    let workflowType: String?
    let createdAt: Date
}

// MARK: - Resolve request

/// `POST /identities/communications/{id}/resolve` request body.
///
/// The wire schema is `anyOf [ios, android, web]` — each platform gets a
/// slightly different optional `billingContext` block. This SDK only sends
/// the iOS variant (`devicePlatform: "ios"`), so we model that shape alone:
/// `billingContext.territory` is the App Store storefront country code
/// (e.g. `"USA"`, `"GBR"`, `"JPN"`), read from `StoreKit.Storefront.current`
/// at resolve time. Sent so the server can render storefront-aware copy
/// / pricing into the offer payload before it hits the bundle.
struct ResolveRequest: Sendable, Codable, Hashable {
    let anonymousId: String?
    let endUserId: String?
    let devicePlatform: DevicePlatform
    let bridgeProtocolVersion: String?
    let webviewVersion: String?
    /// Optional billing context — omit (or pass `nil`) when StoreKit
    /// hasn't surfaced a storefront yet (Simulator without `.storekit`
    /// config, user not signed into the App Store). The server treats
    /// missing context as "no storefront-specific rendering needed".
    let billingContext: BillingContext?

    /// iOS-specific billing context. The `territory` field maps to
    /// `Storefront.countryCode` (ISO 3166-1 alpha-3).
    struct BillingContext: Sendable, Codable, Hashable {
        let territory: String
    }

    enum DevicePlatform: String, Sendable, Codable, Hashable {
        case ios
    }
}

// MARK: - Resolve response

/// Envelope returned by `POST /identities/communications/{id}/resolve`.
/// The server may declare the communication invalid (workflow exited,
/// signature stale, etc.) in which case `data.valid == false` and there
/// is no payload to render.
struct ResolveResponse: Sendable, Codable, Hashable {
    let data: ResolvedCommunication
}

/// Tagged union of the two outcomes the resolve endpoint returns. Custom
/// `Codable` lets the server expand `payload` over time without rebuilding
/// the SDK (we just stash anything we don't recognize as `.unknown`).
enum ResolvedCommunication: Sendable, Codable, Hashable {
    case valid(Valid)
    case invalid

    struct Valid: Sendable, Codable, Hashable {
        let webviewVersion: String?
        let payload: Payload
    }

    private enum CodingKeys: String, CodingKey {
        case valid, webviewVersion, payload
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let isValid = try c.decode(Bool.self, forKey: .valid)
        guard isValid else {
            self = .invalid
            return
        }
        let webviewVersion = try c.decodeIfPresent(String.self, forKey: .webviewVersion)
        let payload = try c.decode(Payload.self, forKey: .payload)
        self = .valid(.init(webviewVersion: webviewVersion, payload: payload))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invalid:
            try c.encode(false, forKey: .valid)
        case .valid(let v):
            try c.encode(true, forKey: .valid)
            try c.encodeIfPresent(v.webviewVersion, forKey: .webviewVersion)
            try c.encode(v.payload, forKey: .payload)
        }
    }
}

// MARK: - Payload

/// Resolved communication payload. Stored as opaque JSON because the bundle
/// owns rendering and consumes the payload through `galva.getMessageData()`
/// as a plain object — the SDK never needs to introspect fields.
struct Payload: Sendable, Codable, Hashable {
    /// Raw JSON object exactly as the server returned it. Becomes the
    /// return value of `galva.getMessageData()` on the bridge.
    let json: [String: AnyJSONValue]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.json = try c.decode([String: AnyJSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(json)
    }
}

// Offer, Survey and CustomPage payloads are deliberately NOT modeled as
// typed Swift structs. The bundle owns rendering; the SDK only forwards
// JSON through `getMessageData()`. Typed models would duplicate fields and
// invite drift the moment the server adds a new field or survey question
// type.
