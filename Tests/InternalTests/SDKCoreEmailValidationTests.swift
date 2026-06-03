//
//  SDKCoreEmailValidationTests.swift
//  GalvaTests
//
//  Verifies the SDK never forwards an invalid email to the server:
//    • createEndpoint / deleteEndpoint drop an invalid `.email` (not enqueued).
//    • A valid email is enqueued normally.
//    • identify drops an invalid `$gv_email` trait while keeping the rest.
//

import Foundation
@testable import Galva
import XCTest

final class SDKCoreEmailValidationTests: XCTestCase {

    // MARK: - createEndpoint

    func test_createEndpoint_validEmail_isEnqueued() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.createEndpoint(.email("peter@example.com"))
        await eventually {
            await Self.endpointEmails(harness).contains("peter@example.com")
        }
    }

    func test_createEndpoint_invalidEmail_isNotEnqueued() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // Invalid first, then a valid "marker" — operations serialize on the
        // GalvaActor in order, so once the marker appears the invalid call has
        // already been processed (and, correctly, dropped).
        await harness.core.createEndpoint(.email("not-an-email"))
        await harness.core.createEndpoint(.email("valid@example.com"))
        await eventually {
            await Self.endpointEmails(harness).contains("valid@example.com")
        }

        let emails = await Self.endpointEmails(harness)
        XCTAssertFalse(emails.contains("not-an-email"),
                       "an invalid email must never be enqueued for the server")
    }

    // MARK: - deleteEndpoint

    func test_deleteEndpoint_invalidEmail_isNotEnqueued() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.deleteEndpoint(.email("bad@@example.com"))
        await harness.core.deleteEndpoint(.email("valid@example.com"))
        await eventually {
            await Self.endpointEmails(harness).contains("valid@example.com")
        }

        let emails = await Self.endpointEmails(harness)
        XCTAssertFalse(emails.contains("bad@@example.com"))
    }

    // MARK: - identify trait

    func test_identify_invalidEmailTrait_isDropped_othersKept() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(
            userId: nil,
            appAccountToken: nil,
            traits: ["$gv_email": .string("bad@"), "plan_tier": .string("pro")]
        )
        await eventually {
            await Self.identifyTraits(harness).contains { $0["plan_tier"] == .string("pro") }
        }

        let ours = await Self.identifyTraits(harness).first { $0["plan_tier"] == .string("pro") }
        XCTAssertNotNil(ours)
        XCTAssertNil(ours?["$gv_email"], "invalid $gv_email must be dropped")
        XCTAssertEqual(ours?["plan_tier"], .string("pro"), "other traits must survive")
    }

    func test_identify_validEmailTrait_isKept() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(
            userId: nil,
            appAccountToken: nil,
            traits: ["$gv_email": .string("good@example.com"), "plan_tier": .string("vip")]
        )
        await eventually {
            await Self.identifyTraits(harness).contains { $0["plan_tier"] == .string("vip") }
        }

        let ours = await Self.identifyTraits(harness).first { $0["plan_tier"] == .string("vip") }
        XCTAssertEqual(ours?["$gv_email"], .string("good@example.com"))
    }

    // MARK: - Helpers

    /// All email addresses across enqueued create/delete-endpoint messages.
    private static func endpointEmails(_ harness: SDKHarness) async -> [String] {
        await harness.consumer.allMessages.compactMap { msg in
            if case .email(let address)? = msg.communicationEndpoint { return address }
            return nil
        }
    }

    /// Traits of every enqueued identify message.
    private static func identifyTraits(_ harness: SDKHarness) async -> [[String: AnyJSONValue]] {
        await harness.consumer.allMessages.compactMap { $0.identifyTraits }
    }
}
