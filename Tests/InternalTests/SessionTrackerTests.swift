//
//  SessionTrackerTests.swift
//  GalvaTests
//
//  Exercises the 30-minute session window, cold-start behaviour,
//  persistence across instances, opt-out gating, and event-property
//  shape (`device_locale`, `os_version`, `app_version`, `sdk_version`).
//
//  Tracker emissions go through a closure injected at init, captured
//  here by a tiny `EmissionRecorder` actor. The tracker never touches
//  the real `SDKCore.shared.track` — tests stay hermetic.
//

import Foundation
@testable import Galva
import XCTest

final class SessionTrackerTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "co.galva.test.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?
            .removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Cold start

    func test_handleForeground_emitsOnColdStart() async {
        let name = suiteName!
        await SessionTrackerHarness.run(suiteName: name) { tracker, recorder in
            await tracker.handleForeground()
            let events = await recorder.events
            XCTAssertEqual(events.map(\.name), ["session_start"])
        }
    }

    // MARK: - Within-window suppression

    func test_handleForeground_withinSessionWindow_isNoOp() async {
        let name = suiteName!
        await SessionTrackerHarness.run(suiteName: name) { tracker, recorder in
            let t0 = Date()
            // Cold start emission.
            await tracker.handleForeground(now: t0)
            // 5 minutes later — still within 30-min window.
            await tracker.handleForeground(now: t0.addingTimeInterval(5 * 60))
            // 29 minutes 59 seconds — still within window.
            await tracker.handleForeground(now: t0.addingTimeInterval(29 * 60 + 59))
            let events = await recorder.events
            XCTAssertEqual(events.count, 1,
                           "subsequent foregrounds inside the 30-min window must not emit")
        }
    }

    // MARK: - After-window emission

    func test_handleForeground_afterSessionWindow_emitsFresh() async {
        let name = suiteName!
        await SessionTrackerHarness.run(suiteName: name) { tracker, recorder in
            let t0 = Date()
            await tracker.handleForeground(now: t0)
            // 30 minutes + 1 second — window expired, emit again.
            await tracker.handleForeground(now: t0.addingTimeInterval(30 * 60 + 1))
            // Another 2 hours later — emit again.
            await tracker.handleForeground(now: t0.addingTimeInterval(30 * 60 + 1 + 2 * 60 * 60))
            let events = await recorder.events
            XCTAssertEqual(events.count, 3)
            XCTAssertTrue(events.allSatisfy { $0.name == "session_start" })
        }
    }

    // MARK: - Persistence across instances

    func test_lastSessionStart_persistsAcrossInstances() async {
        let name = suiteName!

        // First instance — emit, then drop the reference.
        await SessionTrackerHarness.run(suiteName: name) { tracker, _ in
            await tracker.handleForeground()
        }

        // Second instance — same UserDefaults suite. The 30-min window
        // should be re-loaded so the next foreground is suppressed.
        await SessionTrackerHarness.run(suiteName: name) { tracker, recorder in
            // Same wall-clock time, should NOT emit.
            await tracker.handleForeground()
            let events = await recorder.events
            XCTAssertEqual(events.count, 0,
                           "persisted timestamp must suppress the next foreground after restart")
        }
    }

    // MARK: - Opt-out

    func test_handleForeground_doesNotEmit_whenOptedOut() async {
        let name = suiteName!
        let optOutBox = OptOutBox(value: true)
        await SessionTrackerHarness.run(
            suiteName: name,
            isOptedOut: { optOutBox.value }
        ) { tracker, recorder in
            await tracker.handleForeground()
            let events = await recorder.events
            XCTAssertEqual(events.count, 0)
        }
    }

    func test_handleForeground_doesNotBumpTimestamp_whenOptedOut() async {
        // Critical: opting back in after a long opt-out period must
        // produce a session_start. If the tracker bumped its timestamp
        // during opt-out, the 30-min rule would suppress it.
        let name = suiteName!
        let optOutBox = OptOutBox(value: true)
        await SessionTrackerHarness.run(
            suiteName: name,
            isOptedOut: { optOutBox.value }
        ) { tracker, recorder in
            // Opted out — no emission, no timestamp bump.
            await tracker.handleForeground()
            // Opt back in immediately — should emit because no
            // prior session was ever recorded.
            optOutBox.value = false
            await tracker.handleForeground()
            let events = await recorder.events
            XCTAssertEqual(events.count, 1)
        }
    }

    // MARK: - Event properties

    func test_handleForeground_attachesRequiredProperties() async {
        let name = suiteName!
        await SessionTrackerHarness.run(suiteName: name) { tracker, recorder in
            await tracker.handleForeground()
            let events = await recorder.events
            guard let event = events.first else { return XCTFail("no event emitted") }
            // Spec calls out exactly these four properties — no
            // device_country (server derives from IP).
            let keys = Set((event.properties ?? [:]).keys)
            XCTAssertTrue(keys.contains("device_locale"))
            XCTAssertTrue(keys.contains("os_version"))
            XCTAssertTrue(keys.contains("app_version"))
            XCTAssertTrue(keys.contains("sdk_version"))
            XCTAssertFalse(keys.contains("device_country"),
                           "device_country is derived server-side — must NOT be on the wire")
        }
    }

    func test_sdkVersionProperty_matchesSDKConstants() async {
        let name = suiteName!
        await SessionTrackerHarness.run(suiteName: name) { tracker, recorder in
            await tracker.handleForeground()
            let events = await recorder.events
            guard
                let event = events.first,
                case .string(let value)? = event.properties?["sdk_version"]
            else { return XCTFail("sdk_version not present / wrong type") }
            XCTAssertEqual(value, SDKConstants.version)
        }
    }

    func test_handleForeground_emitsPropertiesFromInjectedContextProvider() async {
        // Proves the tracker sources its property bag from the injected
        // ContextProvider (one source of truth shared with every other
        // event's `context`) rather than re-reading platform APIs. The
        // injected snapshot's os_version must surface on the wire.
        let name = suiteName!
        let provider = ContextProvider(snapshot: DeviceSnapshot(osVersion: "99.9"))
        await SessionTrackerHarness.run(
            suiteName: name,
            contextProvider: provider
        ) { tracker, recorder in
            await tracker.handleForeground()
            let events = await recorder.events
            XCTAssertEqual(events.first?.properties?["os_version"], .string("99.9"))
        }
    }
}

// MARK: - Test helpers

/// Records every (event, properties) pair the tracker emits. An actor
/// so concurrent `handleForeground` calls in tests don't race.
private actor EmissionRecorder {
    struct Event {
        let name: String
        let properties: [String: AnyJSONValue]?
    }
    private(set) var events: [Event] = []
    func record(_ event: String, _ properties: [String: AnyJSONValue]?) {
        events.append(.init(name: event, properties: properties))
    }
}

/// Mutable opt-out flag shared between the test and the
/// `isOptedOut` closure passed to the tracker. `@unchecked Sendable`
/// because all access lives on the test's main actor (the tests don't
/// fork the read across threads).
private final class OptOutBox: @unchecked Sendable {
    var value: Bool
    init(value: Bool) { self.value = value }
}

/// Builds an `IdentityStore`-free `SessionTracker` against a per-test
/// `UserDefaults` suite and a recording emission handler. Wraps the
/// `@GalvaActor` plumbing so each test body is a single closure.
private enum SessionTrackerHarness {

    @GalvaActor
    static func run(
        suiteName: String,
        isOptedOut: @escaping @Sendable () -> Bool = { false },
        contextProvider: ContextProvider = ContextProvider(),
        body: @GalvaActor (SessionTracker, EmissionRecorder) async -> Void
    ) async {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to allocate UserDefaults suite")
        }
        let recorder = EmissionRecorder()
        let tracker = SessionTracker(
            defaults: defaults,
            logger: SilentLogger(),
            contextProvider: contextProvider,
            isOptedOut: isOptedOut,
            trackHandler: { event, props in
                await recorder.record(event, props)
            }
        )
        await body(tracker, recorder)
    }
}
