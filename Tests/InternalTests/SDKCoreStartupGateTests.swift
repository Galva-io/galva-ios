//
//  SDKCoreStartupGateTests.swift
//  GalvaTests
//
//  Covers calls the app makes while configure() is still running.
//  `Galva.configure` returns at once and configure() suspends before the SDK
//  can take calls, so an `AppUser.identify` / `AppEvents.track` made right
//  after it used to land mid-configure and be dropped:
//    • calls made while configuring wait for it, then run in call order
//    • calls made after `Galva.configure` claimed configuration, but before
//      configure() started, wait too
//    • they don't wait for the upload of what a previous launch left
//    • an opt-out made while configuring applies at once: configure's own
//      identify and the previous launch's events don't go out
//    • a repeat configure is ignored with a warning — both the synchronous
//      claim and one that lands while the first is suspended
//    • calls made with no configure at all still drop, and a later configure
//      doesn't replay them
//
//  The public entry points reach a harness core through
//  `SDKCoreTestBinding`, and every one of them goes through `submit`.
//  `configureForTesting` shares its startup with production configure.
//  `midConfigure:` holds configure where production suspends (the MainActor
//  snapshot), before the queue exists.
//

import Foundation
@testable import Galva
import XCTest

/// `@MainActor`, like the app: public calls come from the main thread.
@MainActor
final class SDKCoreStartupGateTests: XCTestCase {

    private let repeatWarning = "configure called more than once — ignoring"

    func test_callsMadeWhileConfiguring_runAfterItInCallOrder() async {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        let reached = TestGate()
        let release = TestGate()

        let configuring = Task {
            await harness.configure(midConfigure: {
                await reached.open()
                await release.wait()
            })
        }
        await reached.wait()

        SDKCoreTestBinding.$core.withValue(harness.core) {
            AppUser.identify(userId: "user_42")
            AppEvents.track("app_opened")
        }
        // Let anything already on GalvaActor run while configure is held.
        await Task { @GalvaActor in }.value

        await release.open()
        await configuring.value
        await waitForMessages(harness.consumer, count: 3)

        let messages = await harness.consumer.allMessages
        XCTAssertEqual(messages.count, 3, "the seed identify, then both calls")
        guard messages.count == 3 else { return }
        guard case .identify = messages[1].body else {
            return XCTFail("identify must run before track, got \(messages[1].body)")
        }
        XCTAssertEqual(messages[1].endUserId, "user_42")
        XCTAssertEqual(messages[2].event, "app_opened")
        XCTAssertEqual(messages[2].endUserId, "user_42", "track is attributed to the user identified before it")
    }

    func test_callsMadeAfterClaim_waitForConfigureToStart() async {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }

        // `Galva.configure` claims synchronously; its configure() runs later.
        XCTAssertTrue(harness.core.claimConfiguration())
        harness.core.submit { await $0.track(event: "app_opened", properties: nil) }
        await Task { @GalvaActor in }.value

        await harness.configure()
        await waitForMessages(harness.consumer, count: 2)

        let events = await harness.consumer.consumedEvents
        XCTAssertEqual(events, ["app_opened"])
    }

    func test_callsMadeWhileConfiguring_dontWaitForThePreviousLaunchsUpload() async throws {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        // Events a previous launch left on disk, on a slow network.
        try await harness.storage.storeMessage(.makeTrack(event: "previous_launch"))
        let uploading = TestGate()
        let finishUpload = TestGate()
        await harness.consumer.setBeforeConsume { messages in
            guard messages.contains(where: { $0.event == "previous_launch" }) else { return }
            await uploading.open()
            await finishUpload.wait()
        }

        XCTAssertTrue(harness.core.claimConfiguration())
        SDKCoreTestBinding.$core.withValue(harness.core) {
            AppUser.identify(userId: "user_42")
        }
        let configuring = Task { await harness.configure() }
        await uploading.wait()

        for _ in 0 ..< 200 where AppUser.identifiedUserId != "user_42" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(AppUser.identifiedUserId, "user_42", "identify runs while the previous launch's events upload")

        await finishUpload.open()
        await configuring.value
        await waitForMessages(harness.consumer, count: 3)
        let messages = await harness.consumer.allMessages
        XCTAssertEqual(messages.count, 3, "the previous launch's event, the seed identify, then the call")
        guard messages.count == 3 else { return }
        XCTAssertEqual(messages[0].event, "previous_launch")
        XCTAssertNotNil(messages[1].identifyTraits)
        XCTAssertNil(messages[1].endUserId)
        XCTAssertEqual(messages[2].endUserId, "user_42")
    }

    func test_optOutMadeWhileConfiguring_appliesAtOnce() async throws {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        let defaults = harness.defaults
        defer { SDKCore.setOptedOutFlag(false, defaults: defaults) }
        // Events a previous launch left on disk.
        try await harness.storage.storeMessage(.makeTrack(event: "previous_launch"))
        let reached = TestGate()
        let release = TestGate()

        let configuring = Task {
            await harness.configure(midConfigure: {
                await reached.open()
                await release.wait()
            })
        }
        await reached.wait()

        // What `Galva.setOptOut(true)` does.
        harness.core.requestOptOut(true, defaults: defaults)
        XCTAssertTrue(harness.core.isOptedOut, "Galva.isOptedOut reflects the call at once")

        await release.open()
        await configuring.value
        await Task { @GalvaActor in }.value

        let messages = await harness.consumer.allMessages
        XCTAssertEqual(messages.count, 0, "nothing goes out once the user opted out: \(messages.map(\.body))")
        let stored = try await harness.storage.getQueueSize()
        XCTAssertEqual(stored, 0, "the previous launch's events are purged")
    }

    func test_claimConfiguration_refusesARepeatCallWithAWarning() async {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        let logger = RecordingLogger()
        await harness.core.installLogger(logger)

        XCTAssertTrue(harness.core.claimConfiguration(), "the first Galva.configure claims configuration")
        XCTAssertFalse(harness.core.claimConfiguration(), "a repeat call is refused")
        XCTAssertTrue(
            logger.entries.contains { $0.level == .warning && $0.message == repeatWarning },
            "Got: \(logger.entries.map(\.message))"
        )
    }

    func test_secondConfigureWhileFirstIsSuspended_isIgnoredWithAWarning() async {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        let logger = RecordingLogger()
        let reached = TestGate()
        let release = TestGate()

        let first = Task {
            await harness.configure(logger: logger, midConfigure: {
                await reached.open()
                await release.wait()
            })
        }
        await reached.wait()

        await harness.configure(logger: logger)

        await release.open()
        await first.value

        let seeds = await harness.consumer.allMessages.filter { $0.identifyTraits != nil }
        XCTAssertEqual(seeds.count, 1, "only the first configure seeds an identify")
        XCTAssertEqual(logger.entries.filter { $0.message.hasPrefix("SDK configured") }.count, 1)
        XCTAssertTrue(
            logger.entries.contains { $0.level == .warning && $0.message == repeatWarning },
            "Got: \(logger.entries.map(\.message))"
        )
    }

    func test_callsWithNoConfigure_stillDrop() async {
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        let logger = RecordingLogger()
        await harness.core.installLogger(logger)

        harness.core.submit { await $0.track(event: "early", properties: nil) }
        await Task { @GalvaActor in }.value

        XCTAssertTrue(
            logger.entries.contains { $0.message == "track called before configure() — dropping" },
            "Got: \(logger.entries.map(\.message))"
        )

        await harness.configure()
        let events = await harness.consumer.consumedEvents
        XCTAssertEqual(events, [], "a later configure doesn't replay a dropped call")
    }
}
