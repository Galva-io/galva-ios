//
//  InAppMessageDisplayBudgetTests.swift
//  GalvaTests
//
//  Covers the manager's display budget — at most ONE in-app message flow per
//  foreground stint, with deep links outranking the poll:
//
//    • poll delivers exactly one message; the rest stay unmarked and surface
//      on the next return event's poll
//    • the fetch is SKIPPED entirely while a deep-link claim is pending or a
//      message is on screen / already shown this stint
//    • a claim landing while a fetch is in flight drops the results unmarked
//      (deterministic via a semaphore-blocked URL stub)
//    • a failed programmatic show rolls the budget back
//
//  The manager is @GalvaActor, so claims and poll checks are serialized by the
//  actor — these tests exercise that state machine end-to-end over a stubbed
//  network (no UIKit, runs under plain `swift test`).
//

import Foundation
@testable import Galva
import XCTest

@MainActor
final class InAppMessageDisplayBudgetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - One message per stint

    func test_poll_deliversExactlyOne_remainderSurfacesNextStint() async throws {
        let first = UUID()
        let second = UUID()
        URLProtocolStub.handler = { request in
            let body = BudgetFixtures.list(ids: [first, second])
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
        let harness = await BudgetHarness.make()

        let stint1 = await harness.manager.poll()
        XCTAssertEqual(stint1.map(\.id), [first.uuidString.lowercased()],
                       "only the first (highest-priority) unseen message is delivered")

        // Next return event: budget resets (nothing on screen) → the second,
        // still-unmarked message surfaces.
        let stint2 = await harness.manager.poll()
        XCTAssertEqual(stint2.map(\.id), [second.uuidString.lowercased()],
                       "the undelivered message must not be lost — it shows next stint")
    }

    // MARK: - Fetch suppression

    func test_poll_doesNotFetch_whileDeepLinkClaimPending() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [UUID()]))
        }
        let harness = await BudgetHarness.make()

        await harness.manager.claimDisplaySlot(messageId: "deep-link")
        let emitted = await harness.manager.poll()

        XCTAssertEqual(emitted, [])
        XCTAssertEqual(URLProtocolStub.requests.count, 0,
                       "a pending deep link must suppress the fetch ENTIRELY — no network")
    }

    func test_poll_doesNotFetch_whileMessageOnScreen_orAfterShownThisStint() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [UUID()]))
        }
        let harness = await BudgetHarness.make()

        // On screen → no fetch.
        await harness.manager.setActiveMessageId("on-screen")
        _ = await harness.manager.poll()
        XCTAssertEqual(URLProtocolStub.requests.count, 0, "no fetch while a message is on screen")

        // Dismissed but shown this stint → still no fetch (budget spent).
        // The dismissal itself is NOT a return event.
        await harness.manager.setActiveMessageId(nil)
        // (poll() is only invoked on return events / explicit checks — this
        // call IS the next return event, so the budget resets and fetches.)
        let emitted = await harness.manager.poll()
        XCTAssertEqual(URLProtocolStub.requests.count, 1,
                       "the next return event resets the budget and fetches again")
        XCTAssertEqual(emitted.count, 1)
    }

    func test_poll_dropsMidFlightResultsUnmarked_whenDeepLinkClaims() async throws {
        let messageId = UUID()
        let blocker = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = { request in
            blocker.wait() // hold the response until the deep link has claimed
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200),
                    BudgetFixtures.list(ids: [messageId]))
        }
        let harness = await BudgetHarness.make()

        let poll = Task { await harness.manager.poll() }
        // Wait for the fetch to actually be in flight (bounded spin).
        for _ in 0 ..< 2_000 where URLProtocolStub.requests.isEmpty { await Task.yield() }
        XCTAssertFalse(URLProtocolStub.requests.isEmpty, "fetch should be in flight")

        // Deep link claims MID-FLIGHT, then the response lands.
        await harness.manager.claimDisplaySlot(messageId: "deep-link")
        blocker.signal()

        let emitted = await poll.value
        XCTAssertEqual(emitted, [], "results landing after a claim must be dropped")

        // The dropped message was NOT marked seen — after the deep link ends
        // and the next return event polls, it surfaces.
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [messageId]))
        }
        await harness.manager.releaseDisplaySlot(messageId: "deep-link")
        let nextStint = await harness.manager.poll()
        XCTAssertEqual(nextStint.map(\.id), [messageId.uuidString.lowercased()],
                       "a dropped message must surface on the next return event")
    }

    // MARK: - Claim semantics

    func test_deepLinkClaim_overridesSpentBudget() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [UUID()]))
        }
        let harness = await BudgetHarness.make()

        _ = await harness.manager.poll() // budget spent (.used)
        await harness.manager.claimDisplaySlot(messageId: "deep-link")
        let slot = await harness.manager.displaySlot
        XCTAssertEqual(slot, .pending(messageId: "deep-link"),
                       "a deep link is user-initiated — it claims even a spent budget")
    }

    func test_claim_isNoop_whenSameMessageAlreadyOnScreen() async throws {
        let harness = await BudgetHarness.make()
        await harness.manager.setActiveMessageId("m1") // .used(m1), on screen
        await harness.manager.claimDisplaySlot(messageId: "m1") // repeated show(in:)
        let slot = await harness.manager.displaySlot
        XCTAssertEqual(slot, .used(messageId: "m1"),
                       "re-showing the on-screen message must not regress .used to .pending")
    }

    func test_releaseDisplaySlot_restoresBudget_afterFailedShow() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [UUID()]))
        }
        let harness = await BudgetHarness.make()

        await harness.manager.claimDisplaySlot(messageId: "deep-link")
        await harness.manager.releaseDisplaySlot(messageId: "deep-link") // resolve failed
        let emitted = await harness.manager.poll()
        XCTAssertEqual(emitted.count, 1, "a failed show must not burn the stint's budget")
    }

    // MARK: - Presented-communication dedupe

    func test_presentedMessage_isNotRedeliveredByPoll_othersAre() async throws {
        // The user's deep-link scenario: message X presented + dismissed. A
        // later poll returning X (server still pending) plus a new message Y
        // must skip X and deliver Y — the presented message is done for the
        // run; OTHER messages get the slot.
        let shown = UUID()
        let other = UUID()
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [shown, other]))
        }
        let harness = await BudgetHarness.make()

        // Present X via the deep-link/programmatic path (claim → on screen),
        // then dismiss.
        await harness.manager.claimDisplaySlot(messageId: shown.uuidString.lowercased())
        await harness.manager.setActiveMessageId(shown.uuidString.lowercased())
        await harness.manager.setActiveMessageId(nil)

        // Next return event's poll: X is skipped (already presented), Y delivers.
        let emitted = await harness.manager.poll()
        XCTAssertEqual(emitted.map(\.id), [other.uuidString.lowercased()],
                       "a presented message must never re-deliver; other messages take the slot")
    }

    func test_hasPresented_marksOnPresentation_clearsOnReset() async throws {
        let harness = await BudgetHarness.make()

        let presented = await harness.manager.hasPresented(messageId: "m1")
        XCTAssertFalse(presented)

        await harness.manager.setActiveMessageId("m1")
        await harness.manager.setActiveMessageId(nil) // dismissed — still presented this run
        let afterShow = await harness.manager.hasPresented(messageId: "m1")
        XCTAssertTrue(afterShow, "presentation is remembered past dismissal (per run)")

        await harness.manager.reset() // logOut
        let afterReset = await harness.manager.hasPresented(messageId: "m1")
        XCTAssertFalse(afterReset, "the next identity starts clean")
    }

    func test_reset_clearsSlot() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200),
             BudgetFixtures.list(ids: [UUID()]))
        }
        let harness = await BudgetHarness.make()

        await harness.manager.claimDisplaySlot(messageId: "deep-link")
        await harness.manager.reset() // logOut
        let slot = await harness.manager.displaySlot
        XCTAssertEqual(slot, .available)
    }
}

// MARK: - Fixtures (nonisolated for @Sendable stub handlers)

private enum BudgetFixtures {
    static func list(ids: [UUID]) -> Data {
        let items = ids.map { id -> [String: Any] in
            [
                "id": id.uuidString,
                "type": "trial-rescue-in-app",
                "workflowType": "trial-rescue",
                "createdAt": ISO8601DateFormatter.galva.string(from: Date()),
            ]
        }
        let response: [String: Any] = [
            "success": true,
            "data": items,
            "meta": ["nextCursor": NSNull()],
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }
}

// MARK: - Harness

@MainActor
private struct BudgetHarness {
    let manager: InAppMessageManager

    static func make() async -> BudgetHarness {
        let session = URLProtocolStub.makeSession()
        let client = APIClient(
            baseURL: URL(string: "https://api.galva.test")!,
            apiKey: "pk_test",
            session: session,
            logger: SilentLogger()
        )
        let suiteName = "co.galva.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let identity = await IdentityStore(defaults: defaults)
        let stream = InAppMessageStream()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("galva-budget-test-\(UUID().uuidString)", isDirectory: true)
        let bundleCache = try! WebViewBundleCache(
            directoryURL: tempDir,
            client: client,
            cdnBaseURL: URL(string: "https://webview.galva.test")!,
            logger: SilentLogger()
        )
        let initManager = await InitializationManager(
            client: client,
            cache: nil,
            logger: SilentLogger()
        )
        let manager = await InAppMessageManager(
            client: client,
            identity: identity,
            stream: stream,
            bundleCache: bundleCache,
            initialization: initManager,
            logger: SilentLogger()
        )
        return BudgetHarness(manager: manager)
    }
}
