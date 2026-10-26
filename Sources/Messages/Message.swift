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
//        "type":        "track" | "identify" | "create-communication-endpoint",
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
        case track(event: String, properties: [String: AnyJSONValue]?)
        case createCommunicationEndpoint(CommunicationEndpoint)

        var wireType: WireType {
            switch self {
            case .identify:                     return .identify
            case .track:                        return .track
            case .createCommunicationEndpoint:  return .createCommunicationEndpoint
            }
        }

        enum WireType: String, Sendable, Codable, Hashable {
            case identify
            case track
            case createCommunicationEndpoint = "create-communication-endpoint"
        }
    }

    // MARK: - Codable (flat wire shape)

    private enum CodingKeys: String, CodingKey {
        case messageId, anonymousId, endUserId, timestamp, type, context
        // identify
        case traits
        // track
        case event, properties
        // create-communication-endpoint
        case endpoint
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
        case .track:
            body = .track(
                event: try c.decode(String.self, forKey: .event),
                properties: try c.decodeIfPresent([String: AnyJSONValue].self, forKey: .properties)
            )
        case .createCommunicationEndpoint:
            body = .createCommunicationEndpoint(
                try c.decode(CommunicationEndpoint.self, forKey: .endpoint)
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
        case .track(let event, let properties):
            try c.encode(event, forKey: .event)
            try c.encodeIfPresent(properties, forKey: .properties)
        case .createCommunicationEndpoint(let ep):
            try c.encode(ep, forKey: .endpoint)
        }
    }
}

// MARK: - Batch envelope

struct BatchCollectRequest: Sendable, Codable {
    let messages: [Message]
    let sentAt: Date
}
