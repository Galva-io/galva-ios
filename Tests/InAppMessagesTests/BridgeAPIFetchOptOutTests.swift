//
//  BridgeAPIFetchOptOutTests.swift
//  GalvaTests
//
//  `apiFetch` while the user is opted out:
//    • the in-app page's analytics (`POST /communications/track`, which
//      today's page always sends `shouldRetry` — revflow frontend/in-app
//      utilities/track-events.ts) are neither sent nor queued, and the page
//      gets the answer a delivered one would get, so it carries on
//    • what the user does on the page still goes through: the survey answer,
//      the free-text follow-up, offer acceptance — their responses drive
//      what the page shows next — and `offer_completed`, the one track event
//      the server needs to redeem the offer and stop the run
//
//  Runs on the iOS Simulator (the bridge is UIKit / WebKit only).
//

import Foundation
@testable import Galva
import XCTest
#if canImport(UIKit) && canImport(WebKit)

@MainActor
final class BridgeAPIFetchOptOutTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() async throws {
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    // MARK: - Opted out: the page's analytics

    func test_optedOut_pageAnalytics_isAckedAsQueued_butNeitherSentNorQueued() async throws {
        let harness = await Harness.make(optedOut: true)

        let result = await harness.bridge.handleAPIFetch(payload: Self.track(event: "offer_viewed", shouldRetry: true))

        XCTAssertEqual(try result.get(), .object(["queued": .bool(true)]),
                       "the same ack a queued request gets")
        XCTAssertEqual(URLProtocolStub.requests.count, 0)
        let pending = await harness.durableRequestQueue.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func test_optedOut_inlinePageAnalytics_getsTheTrackEndpointsSuccess_withoutBeingSent() async throws {
        // An inline (non-`shouldRetry`) track gets what the endpoint answers:
        // its output is void, so a 200 with an empty body.
        let harness = await Harness.make(optedOut: true)

        let result = await harness.bridge.handleAPIFetch(payload: Self.track(event: "offer_viewed", shouldRetry: false))

        XCTAssertEqual(try result.get(), .object([
            "status": .int(200),
            "ok": .bool(true),
            "headers": .object([:]),
            "body": .string(""),
            "bodyType": .string("text"),
        ]))
        XCTAssertEqual(URLProtocolStub.requests.count, 0)
    }

    func test_optedOut_everyAnalyticsEvent_isWithheld() async throws {
        let harness = await Harness.make(optedOut: true)

        for event in ["survey_viewed", "offer_viewed", "offer_redeem_failed", "communication_dismissed"] {
            _ = await harness.bridge.handleAPIFetch(payload: Self.track(event: event, shouldRetry: true))
        }

        XCTAssertEqual(URLProtocolStub.requests.count, 0)
        let pending = await harness.durableRequestQueue.pendingCount
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Opted out: what the user does

    func test_optedOut_offerCompleted_isQueuedAndSent() async throws {
        // The purchase's transaction id is how Galva redeems the offer,
        // attributes its renewals and stops the run as converted.
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200), Data())
        }
        let harness = await Harness.make(optedOut: true)

        let result = await harness.bridge.handleAPIFetch(payload: Self.track(event: "offer_completed", shouldRetry: true))

        XCTAssertEqual(try result.get(), .object(["queued": .bool(true)]))
        XCTAssertEqual(URLProtocolStub.requests.compactMap(\.url?.path), ["/communications/track"])
        XCTAssertEqual(CommunicationTrackBody(URLProtocolStub.requests.first?.httpBody)?.event, "offer_completed")
    }

    func test_optedOut_surveyAnswerFollowupAndOfferAcceptance_stillGoThrough() async throws {
        URLProtocolStub.handler = { request in
            (
                URLProtocolStub.httpResponse(
                    url: request.url!,
                    status: 200,
                    headers: ["Content-Type": "application/json"]
                ),
                Data(#"{"data":{}}"#.utf8)
            )
        }
        let harness = await Harness.make(optedOut: true)
        let paths = [
            "/surveyExecutions/se_1/answer",
            "/surveyExecutions/se_1/followup",
            "/offers/accept",
        ]

        for path in paths {
            let result = await harness.bridge.handleAPIFetch(payload: [
                "path": .string(path),
                "method": .string("POST"),
                "headers": .object(["Content-Type": .string("application/json")]),
                "body": .string(#"{"endUserId":"user_1"}"#),
            ])
            guard case .object(let response)? = try result.get() else {
                return XCTFail("\(path): expected a fetch-style response")
            }
            XCTAssertEqual(response["status"], .int(200), path)
            XCTAssertEqual(response["body"], .object(["data": .object([:])]), path)
        }
        XCTAssertEqual(URLProtocolStub.requests.compactMap(\.url?.path), paths)
    }

    // MARK: - Opted in

    func test_optedIn_pageAnalytics_isQueuedAndSent() async throws {
        URLProtocolStub.handler = { request in
            (URLProtocolStub.httpResponse(url: request.url!, status: 200), Data())
        }
        let harness = await Harness.make(optedOut: false)

        let result = await harness.bridge.handleAPIFetch(payload: Self.track(event: "offer_viewed", shouldRetry: true))

        XCTAssertEqual(try result.get(), .object(["queued": .bool(true)]))
        XCTAssertEqual(URLProtocolStub.requests.compactMap(\.url?.path), ["/communications/track"])
    }

    // MARK: - Helpers

    /// The page's `trackEvent` call, as track-events.ts builds it.
    private static func track(event: String, shouldRetry: Bool) -> [String: AnyJSONValue] {
        [
            "path": .string("/communications/track"),
            "method": .string("POST"),
            "headers": .object(["Content-Type": .string("application/json")]),
            "body": .string(#"{"communicationId":"c_1","event":"\#(event)","devicePlatform":"ios"}"#),
            "shouldRetry": .bool(shouldRetry),
        ]
    }

    @MainActor
    private struct Harness {
        let bridge: NativeBridge
        let durableRequestQueue: DurableRequestQueue

        static func make(optedOut: Bool) async -> Harness {
            let (manager, identity, durableRequestQueue) = await makeManager(optedOut: optedOut)
            let bridge = NativeBridge(
                messageId: "m_1",
                messageManager: manager,
                identity: identity,
                storeKitPrefetcher: nil,
                logger: SilentLogger()
            )
            return Harness(bridge: bridge, durableRequestQueue: durableRequestQueue)
        }

        @GalvaActor
        private static func makeManager(
            optedOut: Bool
        ) -> (InAppMessageManager, IdentityStore, DurableRequestQueue) {
            let client = APIClient(
                baseURL: URL(string: "https://api.galva.test")!,
                apiKey: "pk_test",
                session: URLProtocolStub.makeSession(),
                logger: SilentLogger()
            )
            let suiteName = "co.galva.test.\(UUID().uuidString)"
            let identity = IdentityStore(defaults: UserDefaults(suiteName: suiteName)!)
            let bundleCache = try! WebViewBundleCache(
                directoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("galva-bridge-test-\(UUID().uuidString)", isDirectory: true),
                client: client,
                cdnBaseURL: URL(string: "https://webview.galva.test")!,
                logger: SilentLogger()
            )
            let durableRequestQueue = DurableRequestQueue(
                store: InMemoryProxyRequestStore(),
                client: client,
                logger: SilentLogger()
            )
            let manager = InAppMessageManager(
                client: client,
                identity: identity,
                stream: InAppMessageStream(),
                bundleCache: bundleCache,
                initialization: InitializationManager(client: client, cache: nil, logger: SilentLogger()),
                logger: SilentLogger(),
                isOptedOut: { optedOut },
                durableRequestQueue: durableRequestQueue
            )
            return (manager, identity, durableRequestQueue)
        }
    }
}

#endif
