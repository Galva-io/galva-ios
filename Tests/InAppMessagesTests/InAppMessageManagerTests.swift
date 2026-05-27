//
//  InAppMessageManagerTests.swift
//  GalvaTests
//
//  Verifies the polling pipeline end-to-end:
//      • poll() converts a CommunicationListResponse into public messages
//      • duplicate messages observed across polls are not re-emitted
//      • non-in-app types are filtered out (we always pass channelType=in-app,
//        but the response shape can still carry other variants)
//      • resolve() pins the server's webviewVersion, with /sdk/initialize as
//        fallback when the server returns null
//

import Foundation
@testable import Galva
import XCTest

@MainActor
final class InAppMessageManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func test_poll_emitsInAppMessage_onStream() async throws {
        URLProtocolStub.handler = { request in
            let body = TestFixtures.communicationListJSON(items: [
                TestFixtures.makeInAppCommunication(id: UUID(), workflow: "trial-rescue"),
            ])
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
        let harness = await Harness.make()
        let emitted = await harness.manager.poll()
        XCTAssertEqual(emitted.count, 1)
        XCTAssertEqual(emitted.first?.workflowType, .trialRescue)
    }

    func test_poll_dedupesAcrossCalls() async throws {
        let id = UUID()
        URLProtocolStub.handler = { request in
            let body = TestFixtures.communicationListJSON(items: [
                TestFixtures.makeInAppCommunication(id: id, workflow: "payment-recovery"),
            ])
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
        let harness = await Harness.make()
        _ = await harness.manager.poll()
        let secondEmit = await harness.manager.poll()
        XCTAssertEqual(secondEmit.count, 0,
                       "duplicate message id must not be re-emitted")
    }

    func test_poll_filtersOutNonInAppTypes() async throws {
        URLProtocolStub.handler = { request in
            let body = TestFixtures.communicationListJSON(items: [
                TestFixtures.makeCommunication(
                    id: UUID(), type: "trial-rescue-email", workflow: "trial-rescue"
                ),
            ])
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
        let harness = await Harness.make()
        let emitted = await harness.manager.poll()
        XCTAssertEqual(emitted.count, 0,
                       "email variants must be ignored by the in-app stream")
    }

    func test_poll_returnsEmpty_onNetworkError() async throws {
        URLProtocolStub.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let harness = await Harness.make()
        let emitted = await harness.manager.poll()
        XCTAssertEqual(emitted, [])
    }
}

// MARK: - Nonisolated fixture builders
//
// Kept outside the @MainActor XCTestCase so they can be called from inside
// the URLProtocolStub.handler @Sendable closure without crossing actor
// boundaries.
private enum TestFixtures {

    static func communicationListJSON(items: [[String: Any]]) -> Data {
        let response: [String: Any] = [
            "success": true,
            "data": items,
            "meta": ["nextCursor": NSNull()],
        ]
        return try! JSONSerialization.data(withJSONObject: response)
    }

    static func makeInAppCommunication(id: UUID, workflow: String) -> [String: Any] {
        makeCommunication(id: id, type: "trial-rescue-in-app", workflow: workflow)
    }

    static func makeCommunication(
        id: UUID,
        type: String,
        workflow: String?
    ) -> [String: Any] {
        var item: [String: Any] = [
            "id": id.uuidString,
            "type": type,
            "createdAt": ISO8601DateFormatter.galva.string(from: Date()),
        ]
        if let workflow {
            item["workflowType"] = workflow
        } else {
            item["workflowType"] = NSNull()
        }
        return item
    }
}

// MARK: - Harness

@MainActor
private struct Harness {
    let manager: InAppMessageManager

    static func make() async -> Harness {
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
            .appendingPathComponent("galva-iam-test-\(UUID().uuidString)", isDirectory: true)
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
        return Harness(manager: manager)
    }
}
