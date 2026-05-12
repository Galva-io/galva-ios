////
////  DevEx.swift
////  Galva
////
////  Created by Peter Vu on 23/3/26.
////
//
//import UIKit
//import Foundation
//
//class DevEx: NSObject, UIApplicationDelegate {
//    func applicationDidFinishLaunching() {
//        
//        // app id from JSON
//        
//        // InAppMessages.activePaymentRecovery
//        
//        // AppUser.identifiedUserId // read-only, stream
//        // AppUser.identify(userId, appAccountToken: nil)
//        // AppUser.set(.email, "")
//        // AppUser.set(.firstName, "")
//        // AppUser.set("Age", 13)
//        // AppUser.clearIdentify()
//        
//        // AppEvents.track("AddHabitButtonTapped")
//        // AppEvents.enableAutoTracking = false
//        // AppEvents.enableTracking = false
//        
//        // AppConfig.appId = "9249b29418c82afc"
//        
//        // Transactions
//        
//    }
//}
//
//@globalActor
//public actor GalvaActor {
//    public static let shared = GalvaActor()
//    private init() { }
//}
//
//public struct AppConfig: Sendable {
//    static let apiVersion: String = "1.0.0"
//    private static let _overridenAppId = ThreadSafe<String?>(nil)
//    public static var appId: String! {
//        get {
//            if let id = _overridenAppId.value { return id }
//            return Bundle.main.infoDictionary?["GalvaAppId"] as? String
//        }
//        set {
//            _overridenAppId.value = newValue
//        }
//    }
//}
//
//private struct CDPMessageConsumer: MessageConsumer {
//    let appId: String
//    
//    func consume(messages: [Message]) async throws {
//        
//    }
//}
//
//public struct AppUser {
//    private init() { }
//    
//    @GalvaActor
//    static var identifiedUserId: String?
//    
//    @GalvaActor
//    static var anonymousId: String?
//    
//    public static func identify(_ userId: String, appAccountToken: String? = nil) {
//        Task(priority: .background) { @GalvaActor in
//            Self.identifiedUserId = userId
//            await AppConfig.messageQueue.emit(.identify(userId: userId,
//                                                        anonymousId: Self.anonymousId ?? "",
//                                                        apiVersion: AppConfig.apiVersion,
//                                                        traits: nil,
//                                                        context: GalvaApp.currentContext))
//        }
//    }
//}
//
//public struct AppEvents {
//    public static func track(_ eventName: String, attributes: [String: any Sendable]? = nil) {
//        Task(priority: .background) { @GalvaActor in
//            await AppConfig
//                .messageQueue
//                .emit(.track(event: eventName,
//                             userId: AppUser.identifiedUserId,
//                             anonymousId: AppUser.anonymousId,
//                             apiVersion: AppConfig.apiVersion,
//                             properties: attributes,
//                             context: GalvaApp.currentContext))
//        }
//    }
//}
//
//
//internal final class ThreadSafe<Value>: @unchecked Sendable {
//    private var _value: Value
//    private let lock = NSLock()
//    
//    init(_ value: Value) {
//        self._value = value
//    }
//    
//    var value: Value {
//        get {
//            lock.lock()
//            defer { lock.unlock() }
//            return _value
//        }
//        set {
//            lock.lock()
//            _value = newValue
//            lock.unlock()
//        }
//    }
//}
//
