//
//  Galva.swift
//  Galva
//
//  Created by Peter Vu on 12/5/26.
//

import Foundation

public enum Galva {
    public struct AutoTrackCategory: OptionSet, Sendable {
        public var rawValue: UInt
        
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }
        
        public static let lifecycle: AutoTrackCategory = .init(rawValue: 1 << 0)
        public static let transactions: AutoTrackCategory = .init(rawValue: 1 << 1)
    }
    
    public enum LogLevel: Int, Sendable, Comparable {
        case debug    = 0   // dev-only, not persisted by OS
        case info     = 1   // useful but non-essential
        case notice   = 2   // default — significant events
        case warning  = 3   // recoverable issues, retries, edge cases
        case error    = 4   // failed operations
        case critical = 5   // data loss risk, invariant broken
        case off      = 99  // disable entirely
        
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
    
    public static func configure(apiKey: String,
                                 autoTrackCategories: AutoTrackCategory = [.lifecycle, .transactions],
                                 logLevel: LogLevel = .warning) {
        // TODO: Implement
    }
}

public protocol GalvaCompatibleValue: Sendable, Codable { }
extension Int: GalvaCompatibleValue {}
extension String: GalvaCompatibleValue {}
extension Double: GalvaCompatibleValue {}
extension Float: GalvaCompatibleValue {}
extension Bool: GalvaCompatibleValue {}
extension Date: GalvaCompatibleValue {}
extension URL: GalvaCompatibleValue {}
extension UUID: GalvaCompatibleValue {}
extension Int64: GalvaCompatibleValue {}
extension Decimal: GalvaCompatibleValue {}

public typealias EventAttributes = [String: any GalvaCompatibleValue]
public protocol AppEvent: Sendable {
    var eventName: String { get }
    var attributes: EventAttributes? { get }
}

public enum AppEvents {
    public static func track(_ eventName: String, attributes: EventAttributes? = nil) {
        
    }
    
    public static func track<E: AppEvent>(event: E) {
        
    }
    
    public static var enableTracking: Bool {
        get {
            return false // TODO
        } set {
            
        }
    }
}

public protocol AppUserAttribute: Sendable {
    associatedtype Value: GalvaCompatibleValue
    var attributeName: String { get }
}

public extension AppUserAttribute where Self == AppUser.EmailAttribute {
    static var email: AppUser.EmailAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.FullNameAttribute {
    static var fullName: AppUser.FullNameAttribute { .init() }
}


public enum AppUser {
    public static var identifiedUserId: String? {
        nil
    }
    
    public static func identify(userId: String, appAccountToken: UUID? = nil) {
        
    }
    
    public static func `set`<A: AppUserAttribute>(_ attribute: A, _ value: A.Value) {
        
    }
    
    public static func `set`<Value: GalvaCompatibleValue>(_ attributeName: String, _ value: Value) {
        
    }
    
    public static func logOut() {
        
    }
}

public extension AppUser {
    struct EmailAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public var attributeName: String { "$gv_email" }
    }
    
    struct FullNameAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public var attributeName: String { "$gv_fullName" }
    }
}

public protocol InAppMessage: Sendable {
    var messageId: String { get }
    var messageType: InAppMessages.MessageType { get }
    var contentUrl: URL { get }
}

public enum InAppMessages {
    public enum MessageType: String, Sendable, CaseIterable {
        case trialRescue = "trial_rescue"
        case subscriberRescue = "subscriber_rescue"
        case paymentRecovery = "payment_recovery"
        case winback = "winback"
    }
    
    public static func messages(of types: MessageType...) -> AsyncStream<InAppMessage> {
        fatalError()
    }
    
    public static var messages: AsyncStream<InAppMessage> {
        fatalError()
    }
}
