//
//  Context.swift
//  Galva
//
//  INTERNAL wire model for the rich `context` object in
//  /identities/batchCollect. Integrators never construct or read these
//  types — they're populated by ContextProvider on the way to the queue.
//
//  Every field is optional. The SDK populates whatever it can collect
//  locally (app/device/os/screen/locale/timezone/library). The server
//  enriches the rest (ip, network, referrer, userAgentData) from request
//  headers.
//
//  Built once per message by `ContextProvider` from a Sendable
//  `DeviceSnapshot` captured on MainActor during SDK configure. No live
//  UIKit reads on the hot path.
//

import Foundation

struct MessageContext: Sendable, Codable, Hashable {
    var app: App?
    var device: Device?
    var ip: String?
    var library: Library?
    var locale: String?
    var network: Network?
    var os: OS?
    var page: Page?
    var referrer: Referrer?
    var screen: Screen?
    var timezone: String?
    var userAgent: String?
    var userAgentData: UserAgentData?

    struct App: Sendable, Codable, Hashable {
        var name: String?
        var version: String?
        var build: String?
        var namespace: String?
    }

    struct Device: Sendable, Codable, Hashable {
        var id: String?
        var advertisingId: String?
        var adTrackingEnabled: Bool?
        var manufacturer: String?
        var model: String?
        var name: String?
        var type: String?
        var token: String?
        var version: String?
    }

    struct Library: Sendable, Codable, Hashable {
        var name: String?
        var version: String?
    }

    struct Network: Sendable, Codable, Hashable {
        var bluetooth: Bool?
        var carrier: String?
        var cellular: Bool?
        var wifi: Bool?
    }

    struct OS: Sendable, Codable, Hashable {
        var name: String?
        var version: String?
    }

    struct Page: Sendable, Codable, Hashable {
        var path: String?
        var referrer: String?
        var search: String?
        var title: String?
        var url: String?
    }

    struct Referrer: Sendable, Codable, Hashable {
        var id: String?
        var type: String?
        var name: String?
        var url: String?
        var link: String?
    }

    struct Screen: Sendable, Codable, Hashable {
        var width: Double?
        var height: Double?
        var density: Double?
    }

    struct UserAgentData: Sendable, Codable, Hashable {
        var brands: [Brand]?
        var mobile: Bool?
        var platform: String?
        var bitness: String?
        var model: String?
        var platformVersion: String?
        var uaFullVersion: String?

        struct Brand: Sendable, Codable, Hashable {
            var brand: String?
            var version: String?
        }
    }
}
