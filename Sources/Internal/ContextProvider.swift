//
//  ContextProvider.swift
//  Galva
//
//  Gathers device / app / os / locale / screen / library context for every
//  outgoing message.
//
//  Swift 6 strict concurrency note: UIKit/AppKit reads are MainActor-isolated.
//  We snapshot all UI-bound values once on MainActor during SDK configure(),
//  then serve from the Sendable `DeviceSnapshot` on any actor. Non-UI values
//  (Bundle, Locale, TimeZone, uname) are read per-call — they're safe
//  from any context.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Sendable snapshot of UI-bound system properties. Captured once on MainActor.
struct DeviceSnapshot: Sendable, Hashable {
    var deviceId: String?
    var deviceName: String?
    var deviceType: String?
    var osName: String?
    var osVersion: String?
    var screenWidth: Double?
    var screenHeight: Double?
    var screenDensity: Double?

    /// Empty snapshot (used as a safe default before the UI is reachable, or
    /// on platforms where these values don't apply).
    static let empty = DeviceSnapshot()

    /// Capture UI-bound values from the current platform. Must be invoked on
    /// the main actor; SDKCore awaits this through `MainActor.run` in configure().
    @MainActor
    static func capture() -> DeviceSnapshot {
        var snap = DeviceSnapshot()

        #if canImport(UIKit)
        let d = UIDevice.current
        snap.deviceId = d.identifierForVendor?.uuidString.lowercased()
        snap.deviceName = d.name
        snap.deviceType = Self.deviceType(for: d.userInterfaceIdiom)
        snap.osName = d.systemName
        snap.osVersion = d.systemVersion

        let s = UIScreen.main
        snap.screenWidth   = Double(s.bounds.width * s.scale)
        snap.screenHeight  = Double(s.bounds.height * s.scale)
        snap.screenDensity = Double(s.scale)

        #elseif canImport(WatchKit)
        let d = WKInterfaceDevice.current()
        snap.deviceName = d.name
        snap.deviceType = "watch"
        snap.osName = d.systemName
        snap.osVersion = d.systemVersion

        #elseif canImport(AppKit)
        snap.deviceName = Host.current().localizedName
        snap.deviceType = "desktop"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        snap.osName = "macOS"
        snap.osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        if let s = NSScreen.main {
            snap.screenWidth   = Double(s.frame.width * s.backingScaleFactor)
            snap.screenHeight  = Double(s.frame.height * s.backingScaleFactor)
            snap.screenDensity = Double(s.backingScaleFactor)
        }
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        snap.osName = "linux"
        snap.osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif

        return snap
    }

    #if canImport(UIKit)
    private static func deviceType(for idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .unspecified: return "unknown"
        case .phone:       return "phone"
        case .pad:         return "tablet"
        case .tv:          return "tv"
        case .carPlay:     return "carplay"
        case .mac:         return "desktop"
        case .vision:      return "vision"
        @unknown default:  return "unknown"
        }
    }
    #endif
}

/// Builds per-message MessageContext values. Holds a UI snapshot captured at
/// SDK configure time + the latest device token. Safe to call from any actor.
struct ContextProvider: Sendable {
    let deviceToken: String?
    let snapshot: DeviceSnapshot

    init(deviceToken: String? = nil, snapshot: DeviceSnapshot = .empty) {
        self.deviceToken = deviceToken
        self.snapshot = snapshot
    }

    func currentContext() -> MessageContext {
        MessageContext(
            app: appContext(),
            device: deviceContext(),
            ip: nil,
            library: libraryContext(),
            locale: Locale.current.identifier,
            network: nil,
            os: osContext(),
            page: nil,
            referrer: nil,
            screen: screenContext(),
            timezone: TimeZone.current.identifier,
            userAgent: nil,
            userAgentData: nil
        )
    }

    // MARK: - Session event properties

    /// Property bag for the auto-tracked `session_start` event (see
    /// `SessionTracker`). Every value is derived from the same snapshot /
    /// bundle / library constants that feed `currentContext()`, so a
    /// session_start's custom properties never disagree with the `context`
    /// envelope on its own message — notably `os_version` here equals
    /// `context.os.version` (`UIDevice.systemVersion`, e.g. `"17.0"`) rather
    /// than the differently-formatted `ProcessInfo.operatingSystemVersionString`.
    ///
    /// `device_country` is intentionally omitted — the server derives it from
    /// the request IP, which is more reliable than the device Region setting
    /// (especially for travelers).
    func sessionStartEvent() -> SessionStartEvent {
        SessionStartEvent(
            deviceLocale: Locale.current.identifier,
            osVersion: osContext().version ?? "",
            appVersion: appContext().version ?? "",
            sdkVersion: SDKConstants.version
        )
    }

    // MARK: - App (Bundle access — safe from any actor)

    private func appContext() -> MessageContext.App {
        let info = Bundle.main.infoDictionary ?? [:]
        return MessageContext.App(
            name: (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String),
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            namespace: Bundle.main.bundleIdentifier
        )
    }

    // MARK: - Device

    private func deviceContext() -> MessageContext.Device {
        MessageContext.Device(
            id: snapshot.deviceId,
            advertisingId: nil,
            adTrackingEnabled: nil,
            manufacturer: "Apple",
            model: hardwareModel(),
            name: snapshot.deviceName,
            type: snapshot.deviceType,
            token: deviceToken,
            version: nil
        )
    }

    /// Raw machine identifier (e.g. `iPhone15,2`). `uname` is non-UI; safe from
    /// any actor.
    private func hardwareModel() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            if let value = child.value as? Int8, value != 0 {
                identifier.append(Character(UnicodeScalar(UInt8(value))))
            }
        }
        return identifier.isEmpty ? nil : identifier
    }

    // MARK: - OS

    private func osContext() -> MessageContext.OS {
        MessageContext.OS(name: snapshot.osName, version: snapshot.osVersion)
    }

    // MARK: - Screen

    private func screenContext() -> MessageContext.Screen? {
        guard let w = snapshot.screenWidth,
              let h = snapshot.screenHeight,
              let d = snapshot.screenDensity else { return nil }
        return MessageContext.Screen(width: w, height: h, density: d)
    }

    // MARK: - Library

    private func libraryContext() -> MessageContext.Library {
        MessageContext.Library(name: SDKConstants.libraryName, version: SDKConstants.version)
    }
}
