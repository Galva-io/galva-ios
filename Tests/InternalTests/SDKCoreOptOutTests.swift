//
//  SDKCoreOptOutTests.swift
//  GalvaTests
//
//  Verifies the opt-out kill switch:
//
//      • `setOptedOut(true)` causes subsequent `track`, `identify` and
//        `createEndpoint` calls to become silent no-ops (no messages
//        enqueued, no consumer invocation).
//      • The on-disk event queue is purged on the false → true
//        transition so pre-existing events don't leak.
//      • So are the in-app page's analytics (`/communications/track`, all
//        but `offer_completed`) still in the durable apiFetch queue — on
//        the transition, and before any drain while opted out. Its other
//        requests stay. A purged `offer_viewed` / `survey_viewed` leaves its
//        message in `PresentedMessageLog`, so later polls skip it.
//      • `isOptedOut` returns synchronously from the lock-protected
//        mirror, consistent with the most recent `setOptedOut` call.
//      • Toggling back to `false` re-enables event emission without
//        requiring a re-configure.
//

import Foundation
@testable import Galva
import XCTest

final class SDKCoreOptOutTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset the lock-protected mirror so prior tests don't leak
        // into this run (the underlying UserDefaults is per-suite, but
        // the in-memory mirror is process-global).
        SDKCore.setOptedOutFlag(false, defaults: UserDefaults.standard)
    }

    override func tearDown() {
        SDKCore.setOptedOutFlag(false, defaults: UserDefaults.standard)
        super.tearDown()
    }

    // MARK: - Sync read

    func test_isOptedOut_reflectsMostRecentSet() {
        XCTAssertFalse(SDKCore.shared.isOptedOut)
        SDKCore.setOptedOutFlag(true)
        XCTAssertTrue(SDKCore.shared.isOptedOut)
        SDKCore.setOptedOutFlag(false)
        XCTAssertFalse(SDKCore.shared.isOptedOut)
    }

    func test_loadingAtConfigure_keepsAnOptOutAlreadySet() {
        let suiteName = "co.galva.test.\(UUID().uuidString)"
        guard let set = UserDefaults(suiteName: suiteName),
              let loaded = UserDefaults(suiteName: suiteName + ".loaded") else {
            return XCTFail("Failed to allocate UserDefaults suites")
        }
        defer {
            set.removePersistentDomain(forName: suiteName)
            loaded.removePersistentDomain(forName: suiteName + ".loaded")
        }

        // `Galva.setOptOut(true)` racing configure: configure reads the
        // defaults before the opt-out's write lands there.
        SDKCore.setOptedOutFlag(true, defaults: set)
        SDKCore.loadOptedOutFlag(defaults: loaded)

        XCTAssertTrue(SDKCore.shared.isOptedOut)
    }

    // MARK: - Event gating

    func test_track_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // Baseline emission count after configure (the seeded identity
        // message, plus any other startup-time messages).
        let baseline = await harness.consumer.allMessages.count

        await harness.core.setOptedOut(true)
        await harness.core.track(event: "after_optout", properties: nil)
        // Give the queue runloop a chance to drain anything that was
        // already enqueued before the opt-out. New messages should
        // NOT appear in the consumer.
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        let events = await harness.consumer.consumedEvents
        XCTAssertFalse(events.contains("after_optout"),
                       "track must not enqueue when opted out")
    }

    func test_identify_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let baseline = await harness.consumer.allMessages.count
        await harness.core.setOptedOut(true)
        await harness.core.identify(
            userId: "user_after_optout",
            appAccountToken: nil,
            traits: nil
        )
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        // endUserId must remain whatever it was before the opt-out
        // (identify is a no-op, it doesn't even update the cache).
        let userId = await harness.core.currentEndUserId
        XCTAssertNotEqual(userId, "user_after_optout")
    }

    func test_createEndpoint_isNoOp_whenOptedOut() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let baseline = await harness.consumer.allMessages.count
        await harness.core.setOptedOut(true)
        await harness.core.createEndpoint(.pushNotification(platform: .apns, token: "tok"))
        await eventually(timeout: 0.5) {
            await harness.consumer.allMessages.count == baseline
        }
        let messages = await harness.consumer.allMessages
        XCTAssertFalse(messages.contains(where: { $0.communicationEndpoint != nil }))
    }

    // MARK: - Re-enable round-trip

    func test_track_resumesEmitting_afterOptingBackIn() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.setOptedOut(true)
        await harness.core.track(event: "while_opted_out", properties: nil)
        await harness.core.setOptedOut(false)
        await harness.core.track(event: "after_opt_back_in", properties: nil)

        await waitForMessages(harness.consumer, count: 1, timeout: 2.0)
        let events = await harness.consumer.consumedEvents
        XCTAssertTrue(events.contains("after_opt_back_in"))
        XCTAssertFalse(events.contains("while_opted_out"))
    }

    // MARK: - Queue purge

    func test_optingOut_purgesEventsStillQueued() async throws {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        // An event still waiting to upload. Stored straight into storage,
        // so the queue doesn't flush it before the opt-out lands.
        try await harness.storage.storeMessage(.makeTrack(event: "pending_upload"))

        await harness.core.setOptedOut(true)

        let stored = try await harness.storage.getQueueSize()
        XCTAssertEqual(stored, 0, "opting out purges what's still queued")
        let events = await harness.consumer.consumedEvents
        XCTAssertFalse(events.contains("pending_upload"))
    }

    func test_optingOut_purgesThePagesQueuedAnalytics_andKeepsItsOtherRequests() async throws {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let store = await Self.installDurableRequestQueue(on: harness)
        // Queued while opted in, still waiting to deliver (offline). The
        // answer stands in for any other durable request — today's page
        // sends it inline.
        try await store.store(.pageRequest(path: "/communications/track"))
        try await store.store(.pageRequest(path: "/surveyExecutions/se_1/answer"))

        await harness.core.setOptedOut(true)

        let left = try await store.fetchOldest(limit: 10).map(\.path)
        XCTAssertEqual(left, ["/surveyExecutions/se_1/answer"])
    }

    func test_drainWhileOptedOut_dropsThePagesAnalyticsLeftFromBefore() async throws {
        // Opted out before this launch's queue existed (an earlier launch,
        // or `setOptOut` before `configure`): the transition's purge never
        // saw these, so the launch / foreground drain must not send them.
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200), Data())
        }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let store = await Self.installDurableRequestQueue(on: harness)
        try await store.store(.pageRequest(path: "/communications/track"))
        try await store.store(.pageRequest(path: "/surveyExecutions/se_1/answer"))
        SDKCore.setOptedOutFlag(true)

        await harness.core.drainDurableRequests()

        XCTAssertEqual(URLProtocolStub.requests.compactMap(\.url?.path), ["/surveyExecutions/se_1/answer"])
        let pending = try await store.count()
        XCTAssertEqual(pending, 0)
    }

    func test_optingOut_keepsAQueuedOfferCompleted_andRemembersPurgedViewsAsPresented() async throws {
        // Offline purchase while opted in, then an opt-out before the queue
        // drained: the purchase's `offer_completed` must still reach Galva
        // (it redeems the offer and stops the run), while the view, which
        // would have marked the message presented, is dropped — the device
        // remembers that instead.
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let store = await Self.installDurableRequestQueue(on: harness)
        let log = await Self.installPresentedMessageLog(on: harness)
        try await store.store(.pageTrack(event: "offer_viewed", communicationId: "0F8D-VIEWED"))
        try await store.store(.pageTrack(event: "communication_dismissed", communicationId: "c-dismissed"))
        try await store.store(.pageTrack(event: "offer_completed", communicationId: "c-completed"))

        await harness.core.setOptedOut(true)

        let left = try await store.fetchOldest(limit: 10).compactMap { CommunicationTrackBody($0.body)?.event }
        XCTAssertEqual(left, ["offer_completed"])
        let viewedRemembered = await log.contains("0f8d-viewed")
        let dismissedRemembered = await log.contains("c-dismissed")
        XCTAssertTrue(viewedRemembered, "a dropped view stands in for the server's presentedAt")
        XCTAssertFalse(dismissedRemembered, "only views mark a message presented")
    }

    func test_isPageAnalytics_isEveryTrackEventButOfferCompleted() {
        for event in ["offer_viewed", "survey_viewed", "offer_redeem_failed",
                      "communication_dismissed", "some_future_event"] {
            XCTAssertTrue(SDKConstants.isPageAnalytics(path: "/communications/track", body: Self.body(event: event)), event)
        }
        XCTAssertFalse(SDKConstants.isPageAnalytics(path: "/communications/track", body: Self.body(event: "offer_completed")))
        // A body the SDK can't read is withheld, not let through.
        for body in [nil, Data(), Data("not json".utf8), Data("[]".utf8), Data(#"{"event":1}"#.utf8)] {
            XCTAssertTrue(SDKConstants.isPageAnalytics(path: "/communications/track", body: body))
        }
        // Not the track path: never analytics, whatever the body says.
        XCTAssertFalse(SDKConstants.isPageAnalytics(path: "/offers/accept", body: Self.body(event: "offer_viewed")))
    }

    func test_communicationTrackPath_matchesTheRequestThePageSends() {
        // revflow frontend/in-app utilities/track-events.ts posts to exactly
        // "/communications/track"; spellings that resolve to it match too.
        for path in ["/communications/track", "communications/track",
                     "/communications/track?x=1", "/a/../communications/track"] {
            XCTAssertTrue(SDKConstants.isCommunicationTrackPath(path), path)
        }
        // What the user does on the page isn't analytics.
        for path in ["/surveyExecutions/se_1/answer", "/surveyExecutions/se_1/followup",
                     "/offers/accept", "/communications/track-other", "/communications"] {
            XCTAssertFalse(SDKConstants.isCommunicationTrackPath(path), path)
        }
    }

    // MARK: - Helpers

    /// Give the harness core a durable apiFetch queue over an in-memory
    /// store (network to `URLProtocolStub`), as configure does. Returns the
    /// store so a test can seed and inspect it.
    @GalvaActor
    private static func installDurableRequestQueue(on harness: SDKHarness) -> InMemoryProxyRequestStore {
        let store = InMemoryProxyRequestStore()
        harness.core.durableRequestQueue = DurableRequestQueue(
            store: store,
            client: APIClient(
                baseURL: URL(string: "https://api.galva.test")!,
                apiKey: "pk_test",
                session: URLProtocolStub.makeSession(),
                logger: SilentLogger()
            ),
            logger: SilentLogger()
        )
        return store
    }

    /// Give the harness core a `PresentedMessageLog` on its isolated
    /// defaults, as configure does on the standard ones.
    @GalvaActor
    private static func installPresentedMessageLog(on harness: SDKHarness) -> PresentedMessageLog {
        let log = PresentedMessageLog(defaults: harness.defaults)
        harness.core.presentedMessageLog = log
        return log
    }

    private static func body(event: String) -> Data {
        Data(#"{"communicationId":"c_1","event":"\#(event)","timestamp":"2026-10-26T08:14:03.123Z"}"#.utf8)
    }
}

private extension DurableProxyRequest {
    /// A `shouldRetry` apiFetch from the in-app page, as the bridge queues it.
    static func pageRequest(path: String) -> DurableProxyRequest {
        DurableProxyRequest(
            path: path,
            method: "POST",
            body: Data("{}".utf8),
            headers: ["Content-Type": "application/json"]
        )
    }

    /// The page's `trackEvent` call (revflow frontend/in-app
    /// utilities/track-events.ts), as the bridge queues it.
    static func pageTrack(event: String, communicationId: String) -> DurableProxyRequest {
        DurableProxyRequest(
            path: "/communications/track",
            method: "POST",
            body: Data(#"{"communicationId":"\#(communicationId)","event":"\#(event)"}"#.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }
}
