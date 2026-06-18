//
//  SDKCoreDeviceTokenTests.swift
//  GalvaTests
//
//  The device push token is device-scoped: registered once, the SDK keeps it
//  associated with whoever is identified. Verifies:
//    • registerDeviceToken enqueues a push endpoint for the current identity.
//    • Logging in re-registers the token for the new user (no developer resend).
//    • Logging out re-registers it for the fresh anonymous identity.
//

import Foundation
@testable import Galva
import XCTest

final class SDKCoreDeviceTokenTests: XCTestCase {

    func test_registerDeviceToken_registersApnsPushEndpoint() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.registerDeviceToken("deadbeef")
        await eventually {
            await Self.pushEndpoints(harness).contains { platform, token in
                platform == .apns && token == "deadbeef"
            }
        }
    }

    func test_login_reRegistersTokenForNewUser() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // Token arrives while anonymous, then the user logs in.
        await harness.core.registerDeviceToken("deadbeef")
        await eventually { await Self.pushTokens(harness).contains("deadbeef") }

        await harness.core.identify(userId: "user_42", appAccountToken: nil, traits: nil)
        // The SDK re-registers the same token, now bound to the new user —
        // the developer never resent it.
        await eventually {
            await Self.pushEndpointMessages(harness).contains {
                $0.userId == "user_42" && Self.token(of: $0) == "deadbeef"
            }
        }
    }

    func test_logout_reRegistersTokenForAnonymousIdentity() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "user_42", appAccountToken: nil, traits: nil)
        await harness.core.registerDeviceToken("deadbeef")
        await eventually { await Self.pushTokens(harness).contains("deadbeef") }

        let before = await Self.pushEndpointMessages(harness).count
        await harness.core.logOut()
        // After logout the device token re-registers for the new anonymous
        // identity (proving it survived logout and was reused).
        await eventually {
            await Self.pushEndpointMessages(harness).count > before
        }
        let lastAnon = await Self.pushEndpointMessages(harness).last
        XCTAssertEqual(Self.token(of: lastAnon), "deadbeef")
        XCTAssertNil(lastAnon?.userId, "post-logout registration is for the anonymous user")
    }

    // MARK: - Helpers

    private static func pushEndpointMessages(_ harness: SDKHarness) async -> [Message] {
        await harness.consumer.allMessages.filter {
            if case .pushNotification? = $0.communicationEndpoint { return true }
            return false
        }
    }

    private static func pushEndpoints(
        _ harness: SDKHarness
    ) async -> [(CommunicationEndpoint.PushPlatform, String)] {
        await harness.consumer.allMessages.compactMap { msg in
            if case .pushNotification(let platform, let token)? = msg.communicationEndpoint {
                return (platform, token)
            }
            return nil
        }
    }

    private static func pushTokens(_ harness: SDKHarness) async -> [String] {
        await pushEndpoints(harness).map { $0.1 }
    }

    private static func token(of message: Message?) -> String? {
        if case .pushNotification(_, let token)? = message?.communicationEndpoint { return token }
        return nil
    }
}
