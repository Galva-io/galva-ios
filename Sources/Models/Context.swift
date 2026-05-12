//
//  Context.swift
//  Galva
//
//  Mirrors the rich `context` object in /identities/batchCollect.
//
//  Every field is optional. The SDK populates whatever it can collect locally
//  (app/device/os/screen/locale/timezone/library). The server enriches the
//  rest (ip, network, referrer, userAgentData) from request headers.
//
//  Built once per message by `ContextProvider` from a Sendable `DeviceSnapshot`
//  captured on MainActor during SDK configure. No live UIKit reads on the hot
//  path.
//

import Foundation

public struct MessageContext: Sendable, Codable, Hashable {
    public var app: App?
    public var device: Device?
    public var ip: String?
    public var library: Library?
    public var locale: String?
    public var network: Network?
    public var os: OS?
    public var page: Page?
    public var referrer: Referrer?
    public var screen: Screen?
    public var timezone: String?
    public var userAgent: String?
    public var userAgentData: UserAgentData?

    public struct App: Sendable, Codable, Hashable {
        public var name: String?
        public var version: String?
        public var build: String?
        public var namespace: String?
    }

    public struct Device: Sendable, Codable, Hashable {
        public var id: String?
        public var advertisingId: String?
        public var adTrackingEnabled: Bool?
        public var manufacturer: String?
        public var model: String?
        public var name: String?
        public var type: String?
        public var token: String?
        public var version: String?
    }

    public struct Library: Sendable, Codable, Hashable {
        public var name: String?
        public var version: String?
    }

    public struct Network: Sendable, Codable, Hashable {
        public var bluetooth: Bool?
        public var carrier: String?
        public var cellular: Bool?
        public var wifi: Bool?
    }

    public struct OS: Sendable, Codable, Hashable {
        public var name: String?
        public var version: String?
    }

    public struct Page: Sendable, Codable, Hashable {
        public var path: String?
        public var referrer: String?
        public var search: String?
        public var title: String?
        public var url: String?
    }

    public struct Referrer: Sendable, Codable, Hashable {
        public var id: String?
        public var type: String?
        public var name: String?
        public var url: String?
        public var link: String?
    }

    public struct Screen: Sendable, Codable, Hashable {
        public var width: Double?
        public var height: Double?
        public var density: Double?
    }

    public struct UserAgentData: Sendable, Codable, Hashable {
        public var brands: [Brand]?
        public var mobile: Bool?
        public var platform: String?
        public var bitness: String?
        public var model: String?
        public var platformVersion: String?
        public var uaFullVersion: String?

        public struct Brand: Sendable, Codable, Hashable {
            public var brand: String?
            public var version: String?
        }
    }
}
