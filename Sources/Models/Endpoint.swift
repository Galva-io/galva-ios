//
//  Endpoint.swift
//  Galva
//
//  INTERNAL wire-format model for `create-communication-endpoint` messages,
//  which register the device's APNs token for the current identity. The SDK
//  builds these itself — integrators never construct them.
//
//  Wire format:
//    { "channelType": "push-notification", "platform": "apns", "token": "…" }
//

import Foundation

enum CommunicationEndpoint: Sendable, Hashable {
    case pushNotification(platform: PushPlatform, token: String)

    enum PushPlatform: String, Sendable, Codable, Hashable {
        case apns
    }

    enum ChannelType: String, Sendable, Codable, Hashable {
        case pushNotification = "push-notification"
    }

    var channelType: ChannelType {
        switch self {
        case .pushNotification: return .pushNotification
        }
    }
}

extension CommunicationEndpoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case channelType, platform, token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let channel = try c.decode(ChannelType.self, forKey: .channelType)
        switch channel {
        case .pushNotification:
            let platform = try c.decode(PushPlatform.self, forKey: .platform)
            let token = try c.decode(String.self, forKey: .token)
            self = .pushNotification(platform: platform, token: token)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelType, forKey: .channelType)
        switch self {
        case .pushNotification(let platform, let token):
            try c.encode(platform, forKey: .platform)
            try c.encode(token, forKey: .token)
        }
    }
}

// Note: the public `Communication` namespace (and its `PushPlatform` /
// `Channel` enums) was removed — push tokens are registered automatically by
// the SDK from `Galva.application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
// and email is set via `AppUser.set(.email, …)`. The internal
// `CommunicationEndpoint.PushPlatform` / `ChannelType` enums (defined above)
// remain the wire representation.
