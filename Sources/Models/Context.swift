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
    var library: Library?
    var locale: String?
    var os: OS?
    var screen: Screen?
    var timezone: String?

    struct App: Sendable, Codable, Hashable {
        var name: String?
        var version: String?
        var build: String?
        var namespace: String?
    }

    /// No `name` — see `DeviceSnapshot`. Leaving the key out of the model
    /// also drops it from messages an older SDK queued with it: the queue
    /// decodes stored messages and the uploader re-encodes them.
    struct Device: Sendable, Codable, Hashable {
        var id: String?
        var manufacturer: String?
        var model: String?
        var type: String?
        var token: String?
    }

    struct Library: Sendable, Codable, Hashable {
        var name: String?
        var version: String?
    }

    struct OS: Sendable, Codable, Hashable {
        var name: String?
        var version: String?
    }

    struct Screen: Sendable, Codable, Hashable {
        var width: Double?
        var height: Double?
        var density: Double?
    }
}
