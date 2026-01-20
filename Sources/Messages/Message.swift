//
//  Message.swift
//  Galva
//
//  Created by Peter Vu on 11/9/25.
//

import Foundation

extension Message {
    struct TraitUpdateOperation: Codable {
        enum OperationType: String, Codable {
            case set = "$set"
            case setOnce = "$setOnce"
            case setOnInsert = "$setOnInsert"
            case unset = "$unset"
            case rename = "$rename"
            case currentDate = "$currentDate"
            case increment = "$inc"
            case multiply = "$mul"
            case minimum = "$min"
            case maximum = "$max"
            case add = "$add"
        }

        let operation: OperationType
        let value: RevFlowPrimitive?
    }
}

struct Message: Codable {
    let id: String
    let type: MessageType
    var userId: String?
    let anonymousId: String?
    let timestamp: Date
    let apiVersion: String
    let event: String?
    let properties: [String: RevFlowPrimitive]?
    let traits: [String: TraitUpdateOperation]?
    let context: Context

    static func track(
        event: String,
        userId: String?,
        anonymousId: String?,
        timestamp: Date = Date(),
        apiVersion: String,
        properties: [String: Any]?,
        context: Context
    ) -> Self {
        return .init(
            id: UUID().uuidString,
            type: .track,
            userId: userId,
            anonymousId: anonymousId,
            timestamp: timestamp,
            apiVersion: apiVersion,
            event: event,
            properties: properties,
            traits: nil,
            context: context
        )
    }

    static func identify(
        userId: String,
        anonymousId: String,
        timestamp: Date = Date(),
        apiVersion: String,
        traits: [String: TraitUpdateOperation]?,
        context: Context
    ) -> Self {
        return .init(
            id: UUID().uuidString,
            type: .identify,
            userId: userId,
            anonymousId: anonymousId,
            timestamp: timestamp,
            apiVersion: apiVersion,
            event: nil,
            properties: nil,
            traits: traits,
            context: context
        )
    }

    init(
        id: String,
        type: MessageType,
        userId: String?,
        anonymousId: String?,
        timestamp: Date,
        apiVersion: String,
        event: String?,
        properties: [String: Any]?,
        traits: [String: TraitUpdateOperation]?,
        context: Context
    ) {
        self.id = id
        self.type = type
        self.userId = userId
        self.anonymousId = anonymousId
        self.timestamp = timestamp
        self.apiVersion = apiVersion
        self.event = event

        if let properties, !properties.isEmpty {
            self.properties = properties.compactMapValues { RevFlowPrimitive(rawValue: $0) }
        } else {
            self.properties = nil
        }

        self.context = context
        self.traits = traits
    }

    enum MessageType: String, Codable {
        case track
        case identify
        case alias
    }

    struct Context: Codable {
        var app: App
        var device: Device
        var os: OS
        var locale: String
        var timezone: String
        var library: Library
        var extra: [String: RevFlowPrimitive]?
    }

    struct App: Codable {
        var name: String
        var version: String
        var build: String
        var namespace: String
    }

    struct Device: Codable {
        var id: String
        var model: String
        var name: String
        var manufacturer: String
        var type: String
    }

    struct OS: Codable {
        var name: String
        var version: String
    }

    struct Library: Codable {
        var name: String
        var version: String
    }

    struct Locale: Codable {
        var language: String?
    }
}

struct RevFlowPrimitive: Codable {
    private var intValue: Int?
    private var doubleValue: Double?
    private var stringValue: String?
    private var boolValue: Bool?

    init?(rawValue: Any) {
        if let stringValue = rawValue as? String {
            self.stringValue = stringValue
        } else if let intValue = rawValue as? Int {
            self.intValue = intValue
        } else if let doubleValue = rawValue as? Double {
            self.doubleValue = doubleValue
        } else if let boolValue = rawValue as? Bool {
            self.boolValue = boolValue
        } else {
            return nil
        }
    }

    init(intValue: Int) {
        self.intValue = intValue
    }

    init(doubleValue: Double) {
        self.doubleValue = doubleValue
    }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init(boolValue: Bool) {
        self.boolValue = boolValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let intValue = intValue {
            try container.encode(intValue)
        } else if let doubleValue = doubleValue {
            try container.encode(doubleValue)
        } else if let stringValue = stringValue {
            try container.encode(stringValue)
        } else if let boolValue = boolValue {
            try container.encode(boolValue)
        } else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath, debugDescription: "Invalid RevFlowPrimitive"
                )
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self.intValue = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            self.doubleValue = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            self.stringValue = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            self.boolValue = boolValue
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid RevFlowPrimitive"
            )
        }
    }
}
