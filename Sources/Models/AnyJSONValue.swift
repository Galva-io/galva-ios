//
//  AnyJSONValue.swift
//  Galva
//
//  Type-erased JSON value used wherever the server schema is
//  `additionalProperties: {}` (any JSON allowed).
//
//  Used by:
//    • `traits`     — Message.identify
//    • `properties` — Message.track
//    • `categories` — Message.setCommunicationPreference (Bool-only)
//
//  Supports the full JSON value space: null, bool, number, string, array,
//  object. Round-trips losslessly through JSONEncoder/Decoder.
//
//  Construct from any `GalvaCompatibleValue` via `AnyJSONValue(value)` —
//  handles Bool/Int/Double/String/Date/URL/UUID/Decimal natively and falls
//  back to a Codable encode/decode cycle for custom types.
//

import Foundation

/// A type-erased JSON value that conforms to `Codable` and `Sendable`.
/// Used for `traits`, `properties`, and `categories` maps where the server
/// schema is `additionalProperties: {}` (any JSON allowed).
public enum AnyJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])
}

// MARK: - Convenience init from any GalvaCompatibleValue

public extension AnyJSONValue {
    /// Best-effort coercion from a `GalvaCompatibleValue`. Returns `.null` for
    /// values that can't be represented (should never happen for spec types).
    init(_ value: any GalvaCompatibleValue) {
        switch value {
        case let v as Bool:    self = .bool(v)
        case let v as Int:     self = .int(Int64(v))
        case let v as Int64:   self = .int(v)
        case let v as Double:  self = .double(v)
        case let v as Float:   self = .double(Double(v))
        case let v as Decimal: self = .string(v.description)
        case let v as String:  self = .string(v)
        case let v as Date:    self = .string(ISO8601DateFormatter.galva.string(from: v))
        case let v as URL:     self = .string(v.absoluteString)
        case let v as UUID:    self = .string(v.uuidString)
        default:
            // Codable fallback: encode then decode through JSONSerialization.
            if let data = try? JSONEncoder().encode(value),
               let decoded = try? JSONDecoder().decode(AnyJSONValue.self, from: data) {
                self = decoded
            } else {
                self = .null
            }
        }
    }
}

// MARK: - Codable

extension AnyJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([AnyJSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: AnyJSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .int(let v):     try c.encode(v)
        case .double(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }
}

// MARK: - ISO8601 helper (shared)

extension ISO8601DateFormatter {
    /// Galva canonical ISO 8601 with fractional seconds. Used for `timestamp`
    /// and `sentAt` fields on the wire. Thread-safe after configuration; marked
    /// nonisolated(unsafe) to satisfy Swift 6 strict concurrency for shared use.
    nonisolated(unsafe) static let galva: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
