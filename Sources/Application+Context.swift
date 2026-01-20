//
//  Application+Context.swift
//  Galva
//
//  Created by Peter Vu on 12/9/25.
//

#if canImport(UIKit)
    import UIKit
#endif

#if canImport(AppKit)
    import AppKit
#endif

#if canImport(WatchKit)
    import WatchKit
#endif

extension GalvaApp {
    static var currentContext: Message.Context {
        return Message.Context(
            app: createCurrentApp(),
            device: createCurrentDevice(),
            os: createCurrentOS(),
            locale: createCurrentLocale() ?? "Unknown",
            timezone: TimeZone.current.identifier,
            library: createCurrentLibrary(),
            extra: nil
        )
    }

    private static func createCurrentApp() -> Message.App {
        let bundle = Bundle.main
        return Message.App(
            name: bundle.infoDictionary?["CFBundleDisplayName"] as? String ?? bundle
                .infoDictionary?["CFBundleName"] as? String ?? "Unknown",
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            namespace: bundle.bundleIdentifier ?? "unknown.bundle.id"
        )
    }

    private static func createCurrentDevice() -> Message.Device {
        #if canImport(UIKit)
            let device = UIDevice.current
            let deviceType: String

            switch device.userInterfaceIdiom {
            case .phone:
                deviceType = "iPhone"
            case .pad:
                deviceType = "iPad"
            case .tv:
                deviceType = "Apple TV"
            case .carPlay:
                deviceType = "CarPlay"
            case .mac:
                deviceType = "Mac"
            case .vision:
                deviceType = "Apple Vision"
            @unknown default:
                deviceType = "iOS Device"
            }

            return Message.Device(
                id: device.identifierForVendor?.uuidString ?? UUID().uuidString,
                model: deviceType,
                name: device.name,
                manufacturer: "Apple",
                type: deviceType
            )

        #elseif canImport(WatchKit)
            let device = WKInterfaceDevice.current()
            return Message.Device(
                id: UUID().uuidString,
                model: device.model,
                name: device.name,
                manufacturer: "Apple",
                type: "Apple Watch"
            )

        #elseif canImport(AppKit)
            let host = ProcessInfo.processInfo
            return Message.Device(
                id: host.globallyUniqueString,
                model: "Mac",
                name: host.hostName,
                manufacturer: "Apple",
                type: "Mac"
            )

        #else
            return Message.Device(
                id: UUID().uuidString,
                model: "Unknown",
                name: "Unknown Device",
                manufacturer: "Apple",
                type: "Unknown"
            )
        #endif
    }

    private static func createCurrentOS() -> Message.OS {
        #if canImport(UIKit)
            let device = UIDevice.current
            return Message.OS(
                name: device.systemName,
                version: device.systemVersion
            )

        #elseif canImport(WatchKit)
            let device = WKInterfaceDevice.current()
            return Message.OS(
                name: device.systemName,
                version: device.systemVersion
            )

        #elseif canImport(AppKit)
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Message.OS(
                name: "macOS",
                version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            )

        #else
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return Message.OS(
                name: "Unknown",
                version: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            )
        #endif
    }

    private static func createCurrentLibrary() -> Message.Library {
        let bundle = Bundle.main
        let version: String =
            bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? sdkVersion

        return Message.Library(
            name: "Galva",
            version: version
        )
    }

    private static func createCurrentLocale() -> String? {
        let languageCode: String?
        if #available(iOS 16, macOS 13, watchOS 9, tvOS 16, *) {
            languageCode = Foundation.Locale.current.language.languageCode?.identifier
        } else {
            languageCode = Foundation.Locale.current.languageCode
        }
        return languageCode
    }
}
