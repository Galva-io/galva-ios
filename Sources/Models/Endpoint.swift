//
//  Endpoint.swift
//  Galva
//
//  INTERNAL wire-format model for `create-communication-endpoint`,
//  `delete-communication-endpoint`, and `set-communication-preference`
//  messages. Integrators interact with the public `Communication` API in
//  Galva.swift — they never construct these types directly.
//
//  Two channels:
//    • .email(address)
//    • .pushNotification(platform: .apns | .fcm, token: hex)
//
//  Wire format:
//    { "channelType": "email",             "email": "x@y" }
//    { "channelType": "push-notification", "platform": "apns", "token": "…" }
//

import Foundation

enum CommunicationEndpoint: Sendable, Hashable {
    case email(String)
    case pushNotification(platform: PushPlatform, token: String)

    enum PushPlatform: String, Sendable, Codable, Hashable {
        case apns
        case fcm
    }

    enum ChannelType: String, Sendable, Codable, Hashable {
        case email
        case pushNotification = "push-notification"
        case inApp = "in-app"
    }

    var channelType: ChannelType {
        switch self {
        case .email:            return .email
        case .pushNotification: return .pushNotification
        }
    }
}

extension CommunicationEndpoint: Codable {
    private enum CodingKeys: String, CodingKey {
        case channelType, email, platform, token
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let channel = try c.decode(ChannelType.self, forKey: .channelType)
        switch channel {
        case .email:
            self = .email(try c.decode(String.self, forKey: .email))
        case .pushNotification:
            let platform = try c.decode(PushPlatform.self, forKey: .platform)
            let token = try c.decode(String.self, forKey: .token)
            self = .pushNotification(platform: platform, token: token)
        case .inApp:
            throw DecodingError.dataCorruptedError(
                forKey: .channelType, in: c,
                debugDescription: "in-app is not a valid endpoint channel for create/delete"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channelType, forKey: .channelType)
        switch self {
        case .email(let address):
            try c.encode(address, forKey: .email)
        case .pushNotification(let platform, let token):
            try c.encode(platform, forKey: .platform)
            try c.encode(token, forKey: .token)
        }
    }
}

// Note: the public `Communication` namespace (and its `PushPlatform` /
// `Channel` enums) was removed — push tokens are registered automatically by
// the SDK from `Galva.applicationDidRegisterForRemoteNotificationsWithDeviceToken(_:)`,
// and email is set via `AppUser.set(.email, …)`. The internal
// `CommunicationEndpoint.PushPlatform` / `ChannelType` enums (defined above)
// remain the wire representation.
