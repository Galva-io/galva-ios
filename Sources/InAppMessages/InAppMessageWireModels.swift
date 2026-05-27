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
    let success: Bool
    let data: [CommunicationItem]
    let meta: Meta

    struct Meta: Sendable, Codable, Hashable {
        let nextCursor: String?
    }
}

/// One row in the communication list. Drives the public `InAppMessages.Message`.
struct CommunicationItem: Sendable, Codable, Hashable {
    let id: UUID
    let type: CommunicationType
    let workflowType: WorkflowType?
    let createdAt: Date

    /// Server-side enum of channel-specific message types. Includes both
    /// in-app variants and non-in-app variants (we filter on the request
    /// side, so this is mostly for forward compatibility).
    enum CommunicationType: String, Sendable, Codable, Hashable {
        case paymentRecoveryEmail            = "payment-recovery-email"
        case paymentRecoveryPushNotification = "payment-recovery-push-notification"
        case trialRescueEmail                = "trial-rescue-email"
        case trialRescueInApp                = "trial-rescue-in-app"
    }

    /// Workflow the communication came from. Nullable on the wire — the
    /// server returns null for broadcast / manual sends.
    enum WorkflowType: String, Sendable, Codable, Hashable {
        case prechurnSave    = "prechurn-save"
        case paymentRecovery = "payment-recovery"
        case trialRescue     = "trial-rescue"
    }

    // The server returns workflowType as anyOf [enum, null]. Default Codable
    // already accepts both because the field is optional in the Swift type;
    // no custom decoder needed.
}

// MARK: - Resolve request

/// `POST /identities/communications/{id}/resolve` request body.
///
/// The wire schema is `anyOf [ios, android, web]` — each platform gets a
/// slightly different optional `billingContext` block. Since this SDK
/// always sends `devicePlatform: .ios`, we model the iOS shape directly:
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
        case ios, android, web
    }
}

// MARK: - Resolve response

/// Envelope returned by `POST /identities/communications/{id}/resolve`.
/// The server may declare the communication invalid (workflow exited,
/// signature stale, etc.) in which case `data.valid == false` and there
/// is no payload to render.
struct ResolveResponse: Sendable, Codable, Hashable {
    let meta: Meta?
    let data: ResolvedCommunication

    struct Meta: Sendable, Codable, Hashable {
        let requestId: String?
        let timestamp: Date?
    }
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
/// as a plain object — the SDK never needs to introspect fields. The
/// `decodedOffer` accessor lets native code lazily peek at offer-specific
/// fields when wiring StoreKit, without forcing every payload through a
/// typed decoder.
struct Payload: Sendable, Codable, Hashable {
    /// Raw JSON object exactly as the server returned it. Becomes the
    /// return value of `galva.getMessageData()` on the bridge.
    let json: [String: AnyJSONValue]

    init(_ json: [String: AnyJSONValue]) { self.json = json }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.json = try c.decode([String: AnyJSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(json)
    }

    /// Best-effort typed view of an offer payload. Returns `nil` for surveys,
    /// custom pages, or any payload that doesn't carry the offer required
    /// fields (`plan`, `signature`, `billingPlatforms`).
    var decodedOffer: Offer? {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = ISO8601DateFormatter.galva.date(from: s) { return d }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let d = fallback.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid ISO 8601 date: \(s)"
            )
        }
        guard
            let data = try? encoder.encode(json),
            let offer = try? decoder.decode(Offer.self, from: data)
        else {
            return nil
        }
        return offer
    }
}

// MARK: Offer

struct Offer: Sendable, Codable, Hashable {
    let appId: UUID
    let communicationId: UUID
    let endUserId: String
    let identityId: UUID
    let app: App
    let plan: Plan
    let amount: Double?
    let expiresAt: Date
    let title: String
    let subtitle: String?
    let benefits: [String]?
    let price: Price?
    let inAppDeepLink: String?
    let billingPlatforms: [BillingPlatform]
    /// HMAC-signed token. Bundle echoes it back when accepting the offer so
    /// the server can verify the render → purchase chain.
    let signature: String

    struct App: Sendable, Codable, Hashable {
        let name: String
        let logoUrl: String
    }

    struct Plan: Sendable, Codable, Hashable {
        let id: String
        let versionId: String
        let name: String
    }

    struct Price: Sendable, Codable, Hashable {
        let initPrice: Double
        let offerPrice: Double
        let currencyCode: String
    }

    struct BillingPlatform: Sendable, Codable, Hashable {
        let platform: Platform
        let platformConfigId: String
        let price: Price?

        enum Platform: String, Sendable, Codable, Hashable {
            case appstore, playstore, paddle
        }
    }
}

// Survey and CustomPage payloads carry the same identity envelope as Offer
// without the offer-specific fields. The bundle owns rendering; the SDK
// only forwards JSON through `getMessageData()`. We deliberately do NOT
// model them as typed Swift structs — that would duplicate fields and
// invite drift the moment the server adds a new survey question type.
