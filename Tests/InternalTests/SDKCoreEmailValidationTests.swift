//
//  SDKCoreEmailValidationTests.swift
//  GalvaTests
//
//  Verifies the SDK never forwards an invalid email to the server:
//    • identify drops an invalid `$gv_email` trait while keeping the rest.
//    • A valid `$gv_email` trait is enqueued normally.
//

import Foundation
@testable import Galva
import XCTest

final class SDKCoreEmailValidationTests: XCTestCase {

    // MARK: - identify trait

    func test_identify_invalidEmailTrait_isDropped_othersKept() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(
            userId: nil,
            appAccountToken: nil,
            traits: [BuiltInTraitKey.email: .string("bad@"), "plan_tier": .string("pro")]
        )
        await eventually {
            await Self.identifyTraits(harness).contains { $0["plan_tier"] == .string("pro") }
        }

        let ours = await Self.identifyTraits(harness).first { $0["plan_tier"] == .string("pro") }
        XCTAssertNotNil(ours)
        XCTAssertNil(ours?[BuiltInTraitKey.email], "invalid $gv_email must be dropped")
        XCTAssertEqual(ours?["plan_tier"], .string("pro"), "other traits must survive")
    }

    func test_identify_validEmailTrait_isKept() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(
            userId: nil,
            appAccountToken: nil,
            traits: [BuiltInTraitKey.email: .string("good@example.com"), "plan_tier": .string("vip")]
        )
        await eventually {
            await Self.identifyTraits(harness).contains { $0["plan_tier"] == .string("vip") }
        }

        let ours = await Self.identifyTraits(harness).first { $0["plan_tier"] == .string("vip") }
        XCTAssertEqual(ours?[BuiltInTraitKey.email], .string("good@example.com"))
    }

    // MARK: - Helpers

    /// Traits of every enqueued identify message.
    private static func identifyTraits(_ harness: SDKHarness) async -> [[String: AnyJSONValue]] {
        await harness.consumer.allMessages.compactMap { $0.identifyTraits }
    }
}
