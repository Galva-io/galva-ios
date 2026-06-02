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

/// INTERNAL type-erased JSON value used for the wire `traits`, `properties`,
/// and `categories` maps. Integrators interact with `GalvaCompatibleValue`
/// instead — `AnyJSONValue` is constructed by the SDK on the way to the
/// uploader.
enum AnyJSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyJSONValue])
    case object([String: AnyJSONValue])
}

// MARK: - Convenience init from any GalvaCompatibleValue

extension AnyJSONValue {
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
        case let v as UUID:    self = .string(v.uuidString.lowercased())
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

// MARK: - Best-effort coercion from untyped `Any`

extension AnyJSONValue {

    /// Best-effort coercion from an untyped `Any`, returning `nil` for values
    /// that can't be represented as JSON. Lets the public `[String: Any]`
    /// event/track API accept a loose dictionary and silently drop anything
    /// that isn't JSON-compatible, so integrators don't have to pre-convert.
    ///
    /// Handles, in order:
    ///   • an already-built `AnyJSONValue` (pass-through),
    ///   • any `GalvaCompatibleValue` — every Swift scalar the SDK supports
    ///     (`Bool`/`Int`/`Int64`/`Double`/`Float`/`String`/`Date`/`URL`/
    ///     `UUID`/`Decimal`) plus custom `Codable` conformers,
    ///   • Foundation/JSON-sourced values: `NSNull`, `NSNumber`
    ///     (bool vs. integer vs. floating distinguished correctly), `NSString`,
    ///   • nested `[Any]` / `[String: Any]` (recursively coerced; incompatible
    ///     elements/entries are dropped).
    /// Anything else (custom classes, closures, …) returns `nil`.
    static func coercing(_ value: Any) -> AnyJSONValue? {
        switch value {
        case let v as AnyJSONValue:
            return v
        case let v as any GalvaCompatibleValue:
            // Covers all Swift-native scalars + custom Codable conformers with
            // correct typing (e.g. Decimal → string to preserve precision).
            return AnyJSONValue(v)
        case is NSNull:
            return .null
        case let v as NSNumber:
            // JSON-sourced numbers arrive as NSNumber. A boolean NSNumber is a
            // CFBoolean — distinguish it so `true` doesn't become `1`.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            let objCType = String(cString: v.objCType)
            if objCType == "f" || objCType == "d" { return .double(v.doubleValue) }
            return .int(v.int64Value)
        case let v as String:
            // Catches `NSString` (bridges to `String`); native `String` was
            // already handled by the `GalvaCompatibleValue` case above.
            return .string(v)
        case let v as [Any]:
            return .array(v.compactMap { coercing($0) })
        case let v as [String: Any]:
            return .object(coercing(dictionary: v))
        default:
            return nil
        }
    }

    /// Coerce every entry of a `[String: Any]` to `AnyJSONValue`, dropping keys
    /// whose value isn't JSON-compatible. Used by the `[String: Any]` track API.
    static func coercing(dictionary raw: [String: Any]) -> [String: AnyJSONValue] {
        var out: [String: AnyJSONValue] = [:]
        out.reserveCapacity(raw.count)
        for (key, value) in raw {
            if let coerced = coercing(value) { out[key] = coerced }
        }
        return out
    }
}

// MARK: - Codable

extension AnyJSONValue: Codable {
    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
