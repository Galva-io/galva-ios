//
//  SDKCoreConfigurationTests.swift
//  GalvaTests
//
//  Covers SDKCore startup behaviour:
//    • configure runs exactly once (idempotent)
//    • configure seeds an initial identify message tagged with the
//      device's built-in traits ($gv_timezone, $gv_languageCode), so the
//      server knows about the anonymous user before any explicit
//      identify() call
//    • calls made before configure() are dropped (with a warning)
//      instead of crashing
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class SDKCoreConfigurationTests: XCTestCase {

    func test_configure_marksSDKAsConfigured() async {
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        XCTAssertFalse(harness.core.isConfigured, "should be unconfigured at construction")
        await harness.configure()
        XCTAssertTrue(harness.core.isConfigured, "configure() should set isConfigured=true")
    }

    func test_configure_isIdempotent_secondCallIsNoOp() async {
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.configure()
        let firstCount = await harness.consumer.callCount

        // Second configure should not re-emit the seed identify or re-wire
        // anything; the consumer call count must be unchanged.
        await harness.configure()
        let secondCount = await harness.consumer.callCount

        XCTAssertEqual(firstCount, secondCount,
                       "Second configure() must be a no-op (got \(firstCount) → \(secondCount))")
    }

    func test_configure_seedsInitialIdentifyForAnonymousUser() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let messages = await harness.consumer.allMessages
        XCTAssertEqual(messages.count, 1, "configure should emit exactly one seed message")

        guard case .identify = messages[0].body else {
            return XCTFail("Seed message should be an identify, got \(messages[0].body)")
        }

        XCTAssertNotNil(messages[0].anonymousId)
        XCTAssertNil(messages[0].endUserId, "Seed identify is anonymous-only")
    }

    func test_configure_seedIdentifyCarriesDeviceTraits() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let messages = await harness.consumer.allMessages
        guard let first = messages.first,
              case .identify(let traits) = first.body,
              let traits = traits else {
            return XCTFail("Expected an identify message with non-nil traits")
        }
        XCTAssertNotNil(traits["$gv_timezone"], "Device timezone should be auto-attached")
        XCTAssertNotNil(traits["$gv_languageCode"], "Device language code should be auto-attached")
    }

    // MARK: - Pre-configure safety

    func test_track_beforeConfigure_doesNotEmit() async {
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.core.track(event: "early-bird", properties: nil)

        // Give the actor a chance to process anything (it shouldn't).
        try? await Task.sleep(nanoseconds: 50_000_000)

        let count = await harness.consumer.callCount
        XCTAssertEqual(count, 0, "track before configure must not reach the consumer")
    }

    func test_identify_beforeConfigure_doesNotEmit() async {
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "early", appAccountToken: nil, traits: nil)
        try? await Task.sleep(nanoseconds: 50_000_000)

        let count = await harness.consumer.callCount
        XCTAssertEqual(count, 0, "identify before configure must not reach the consumer")
    }
}
