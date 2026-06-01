//
//  Message.swift
//  Galva
//
//  Wire-format message for POST /identities/batchCollect.
//
//  Shape (matches OpenAPI exactly — flat object, type-discriminated):
//
//      {
//        "messageId":   "<uuid v7>",
//        "anonymousId": "...",
//        "endUserId":   "...",       // optional
//        "timestamp":   "2026-05-12T…Z",
//        "type":        "track" | "identify" | "alias" | "create-…" | …,
//        "context":     { … },        // optional, server-enriched
//        …type-specific fields…
//      }
//
//  The Swift representation uses an enum (`Body`) with associated values for
//  type-safe construction, and a custom Codable to flatten / un-flatten the
//  wire shape. New message variants go in `Body` + `Body.WireType`.
//

import Foundation

struct Message: Sendable, Hashable, Codable {
    /// Client-generated UUID v7 (time-ordered). Becomes `messageId` on the wire.
    let messageId: UUID
    let anonymousId: String?
    let endUserId: String?
    let timestamp: Date
    let context: MessageContext?
    let body: Body

    init(
        messageId: UUID = UUIDv7.next(),
        anonymousId: String?,
        endUserId: String?,
        timestamp: Date = Date(),
        context: MessageContext?,
        body: Body
    ) {
        self.messageId = messageId
        self.anonymousId = anonymousId
        self.endUserId = endUserId
        self.timestamp = timestamp
        self.context = context
        self.body = body
    }

    /// Stable per-record id (string form of `messageId`) used by storage layer.
    var id: String { messageId.uuidString.lowercased() }

    // MARK: - Body

    enum Body: Sendable, Hashable {
        case identify(traits: [String: AnyJSONValue]?)
        case alias(previousId: String, targetId: String)
        case track(event: String,
                   properties: [String: AnyJSONValue]?,
                   sourceType: TrackSource?,
                   sourceId: String?)
        case createCommunicationEndpoint(CommunicationEndpoint)
        case deleteCommunicationEndpoint(CommunicationEndpoint)
        case setCommunicationPreference(channelType: CommunicationEndpoint.ChannelType,
                                        disabled: Bool?,
                                        categories: [String: Bool]?)

        enum TrackSource: String, Sendable, Codable, Hashable {
            case profile
            case product
            case plan
            case productBilling = "product-billing"
            case entitlement
        }

        var wireType: WireType {
            switch self {
            case .identify:                     return .identify
            case .alias:                        return .alias
            case .track:                        return .track
            case .createCommunicationEndpoint:  return .createCommunicationEndpoint
            case .deleteCommunicationEndpoint:  return .deleteCommunicationEndpoint
            case .setCommunicationPreference:   return .setCommunicationPreference
            }
        }

        enum WireType: String, Sendable, Codable, Hashable {
            case identify
            case alias
            case track
            case createCommunicationEndpoint = "create-communication-endpoint"
            case deleteCommunicationEndpoint = "delete-communication-endpoint"
            case setCommunicationPreference  = "set-communication-preference"
        }
    }

    // MARK: - Codable (flat wire shape)

    private enum CodingKeys: String, CodingKey {
        case messageId, anonymousId, endUserId, timestamp, type, context
        // identify
        case traits
        // alias
        case previousId, targetId
        // track
        case event, properties, sourceType, sourceId
        // create/delete-communication-endpoint
        case endpoint
        // set-communication-preference
        case channelType, disabled, categories
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(UUID.self, forKey: .messageId)
        anonymousId = try c.decodeIfPresent(String.self, forKey: .anonymousId)
        endUserId = try c.decodeIfPresent(String.self, forKey: .endUserId)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        context = try c.decodeIfPresent(MessageContext.self, forKey: .context)

        let type = try c.decode(Body.WireType.self, forKey: .type)
        switch type {
        case .identify:
            body = .identify(
                traits: try c.decodeIfPresent([String: AnyJSONValue].self, forKey: .traits)
            )
        case .alias:
            body = .alias(
                previousId: try c.decode(String.self, forKey: .previousId),
                targetId: try c.decode(String.self, forKey: .targetId)
            )
        case .track:
            body = .track(
                event: try c.decode(String.self, forKey: .event),
                properties: try c.decodeIfPresent([String: AnyJSONValue].self, forKey: .properties),
                sourceType: try c.decodeIfPresent(Body.TrackSource.self, forKey: .sourceType),
                sourceId: try c.decodeIfPresent(String.self, forKey: .sourceId)
            )
        case .createCommunicationEndpoint:
            body = .createCommunicationEndpoint(
                try c.decode(CommunicationEndpoint.self, forKey: .endpoint)
            )
        case .deleteCommunicationEndpoint:
            body = .deleteCommunicationEndpoint(
                try c.decode(CommunicationEndpoint.self, forKey: .endpoint)
            )
        case .setCommunicationPreference:
            body = .setCommunicationPreference(
                channelType: try c.decode(CommunicationEndpoint.ChannelType.self, forKey: .channelType),
                disabled: try c.decodeIfPresent(Bool.self, forKey: .disabled),
                categories: try c.decodeIfPresent([String: Bool].self, forKey: .categories)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(messageId, forKey: .messageId)
        try c.encodeIfPresent(anonymousId, forKey: .anonymousId)
        try c.encodeIfPresent(endUserId, forKey: .endUserId)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(body.wireType, forKey: .type)
        try c.encodeIfPresent(context, forKey: .context)

        switch body {
        case .identify(let traits):
            try c.encodeIfPresent(traits, forKey: .traits)
        case .alias(let previousId, let targetId):
            try c.encode(previousId, forKey: .previousId)
            try c.encode(targetId, forKey: .targetId)
        case .track(let event, let properties, let sourceType, let sourceId):
            try c.encode(event, forKey: .event)
            try c.encodeIfPresent(properties, forKey: .properties)
            try c.encodeIfPresent(sourceType, forKey: .sourceType)
            try c.encodeIfPresent(sourceId, forKey: .sourceId)
        case .createCommunicationEndpoint(let ep),
             .deleteCommunicationEndpoint(let ep):
            try c.encode(ep, forKey: .endpoint)
        case .setCommunicationPreference(let channelType, let disabled, let categories):
            try c.encode(channelType, forKey: .channelType)
            try c.encodeIfPresent(disabled, forKey: .disabled)
            try c.encodeIfPresent(categories, forKey: .categories)
        }
    }
}

// MARK: - Batch envelope

struct BatchCollectRequest: Sendable, Codable {
    let messages: [Message]
    let sentAt: Date
}

// MARK: - Legacy compatibility

extension Message {
    /// Coarse type discriminator preserved for compatibility with older test
    /// code. New code should switch on `body` directly.
    enum MessageType: Equatable, Sendable {
        case track
        case identify
        case alias
        case createCommunicationEndpoint
        case deleteCommunicationEndpoint
        case setCommunicationPreference
    }

    var type: MessageType {
        switch body {
        case .track:                         return .track
        case .identify:                      return .identify
        case .alias:                         return .alias
        case .createCommunicationEndpoint:   return .createCommunicationEndpoint
        case .deleteCommunicationEndpoint:   return .deleteCommunicationEndpoint
        case .setCommunicationPreference:    return .setCommunicationPreference
        }
    }

    /// Legacy alias for `endUserId` used by older test code.
    var userId: String? { endUserId }

    /// Convenience accessor for the event name of a `.track` body.
    var event: String? {
        if case .track(let event, _, _, _) = body { return event }
        return nil
    }

    /// Convenience accessor for properties (`.track`) or traits (`.identify`).
    /// Older tests treat both as a single dictionary.
    var properties: [String: AnyJSONValue]? {
        switch body {
        case .track(_, let props, _, _): return props
        case .identify(let traits):      return traits
        default:                         return nil
        }
    }

    /// Convenience accessor for the traits dictionary of an `.identify` body.
    var traits: [String: AnyJSONValue]? {
        if case .identify(let traits) = body { return traits }
        return nil
    }
}
