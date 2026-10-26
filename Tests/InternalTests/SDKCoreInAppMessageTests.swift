//
//  SDKCoreInAppMessageTests.swift
//  GalvaTests
//
//  In-app messaging through SDKCore:
//    • a poll in flight for one user when `logOut` or a user switch lands
//      publishes nothing to the next identity — even when it returns while
//      the switch's own identify is still uploading
//    • a check made right after a user switch delivers the new user's
//      message, and keeps it held for a `.manual` loop not yet started
//    • (UIKit) a presentation that fails throws an `InAppMessages.Error`,
//      and the message it was for is delivered again next stint
//    • (UIKit) a failed automatic presentation is logged at `.warning`
//
//  Network goes to `URLProtocolStub`. The UIKit tests run on the iOS
//  Simulator, where the test runner has no window scene to present on.
//

import Foundation
@_spi(Testing) @testable import Galva
import XCTest
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
#endif

@MainActor
final class SDKCoreInAppMessageTests: XCTestCase {

    // MARK: - Identity changes mid-poll

    func test_logOut_dropsPollInFlightForThePreviousUser() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)
        let manager = await harness.installInAppMessaging()
        let blocker = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = Self.listHandler(ids: [UUID()], blockedBy: blocker)

        let poll = Task { await manager.poll() }
        await Self.waitForRequest()
        await harness.core.logOut()
        blocker.signal()

        let delivered = await poll.value
        XCTAssertEqual(delivered, [], "user_A's message must not reach the logged-out user")
        let stream = await harness.core.inAppMessageStream
        XCTAssertNil(stream.heldMessage)
    }

    func test_switchingUsers_dropsPollInFlightForThePreviousUser() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)
        let manager = await harness.installInAppMessaging()
        let blocker = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = Self.listHandler(ids: [UUID()], blockedBy: blocker)

        let poll = Task { await manager.poll() }
        await Self.waitForRequest()
        await harness.core.identify(userId: "user_B", appAccountToken: nil, traits: nil)
        blocker.signal()

        let delivered = await poll.value
        XCTAssertEqual(delivered, [], "user_A's message must not reach user_B")
        let stream = await harness.core.inAppMessageStream
        XCTAssertNil(stream.heldMessage)
    }

    func test_switchingUsers_dropsPollForThePreviousUser_thatLandsMidSwitch() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)
        let manager = await harness.installInAppMessaging()
        let blocker = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = Self.listHandler(ids: [UUID()], blockedBy: blocker)
        let upload = await Self.holdUpload(of: "user_B", in: harness)

        let poll = Task { await manager.poll() }
        await Self.waitForRequest()
        // user_A's poll returns while user_B's identify is still uploading.
        let identify = Task { await harness.core.identify(userId: "user_B", appAccountToken: nil, traits: nil) }
        await upload.reached.wait()
        blocker.signal()

        let delivered = await poll.value
        await upload.release.open()
        await identify.value
        XCTAssertEqual(delivered, [], "user_A's message must not reach user_B")
    }

    func test_checkingForMessagesRightAfterSwitchingUsers_deliversTheNewUsersMessage() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)
        let manager = await harness.installInAppMessaging()
        let messageId = UUID()
        let blocker = DispatchSemaphore(value: 0)
        URLProtocolStub.handler = Self.listHandler(ids: [messageId], blockedBy: blocker)
        let upload = await Self.holdUpload(of: "user_B", in: harness)

        // `AppUser.identify(userId: "user_B")`, then
        // `InAppMessages.checkForMessages()`: the check starts while the
        // identify is still uploading.
        let identify = Task { await harness.core.identify(userId: "user_B", appAccountToken: nil, traits: nil) }
        await upload.reached.wait()
        let check = Task { await manager.checkForMessages() }
        await Self.waitForRequest()
        await upload.release.open()
        await identify.value
        blocker.signal()

        let delivered = await check.value
        let query = URLProtocolStub.requests.first?.url?.query ?? ""
        XCTAssertTrue(query.contains("endUserId=user_B"), "the check is for user_B: \(query)")
        XCTAssertEqual(delivered.map(\.id), [messageId.uuidString.lowercased()], "user_B's own message must be delivered")
    }

    func test_messageHeldForTheNewUserMidSwitch_isKept() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.core.identify(userId: "user_A", appAccountToken: nil, traits: nil)
        let manager = await harness.installInAppMessaging()
        let messageId = UUID()
        URLProtocolStub.handler = Self.listHandler(ids: [messageId])
        let upload = await Self.holdUpload(of: "user_B", in: harness)

        // Nobody reads the stream yet (`.manual`, the app's loop hasn't
        // started), so user_B's message is held for it.
        let identify = Task { await harness.core.identify(userId: "user_B", appAccountToken: nil, traits: nil) }
        await upload.reached.wait()
        let delivered = await manager.checkForMessages()
        XCTAssertEqual(delivered.map(\.id), [messageId.uuidString.lowercased()])
        await upload.release.open()
        await identify.value

        let stream = await harness.core.inAppMessageStream
        XCTAssertEqual(stream.heldMessage?.id, messageId.uuidString.lowercased(), "user_B's message must wait for the app's loop")
    }

    #if canImport(UIKit) && canImport(WebKit)

    // MARK: - Failed presentation (UIKit)

    func test_show_withNoWindow_throwsNoPresentingViewController_andDeliversTheMessageAgain() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let manager = await harness.installInAppMessaging()
        let messageId = UUID()
        URLProtocolStub.handler = Self.listHandler(ids: [messageId])

        let delivered = await manager.poll()
        XCTAssertEqual(delivered.map(\.id), [messageId.uuidString.lowercased()])
        guard let message = delivered.first else { return }

        do {
            try await harness.core.showInAppMessage(message)
            XCTFail("show must throw with no window to present on")
        } catch {
            XCTAssertEqual(error as? InAppMessages.Error, .noPresentingViewController, "\(error)")
        }

        let nextStint = await manager.poll()
        XCTAssertEqual(nextStint.map(\.id), [message.id], "the message never reached the screen — deliver it again")
    }

    func test_prepare_whenResolveFails_throwsRequestFailed_andDeliversTheMessageAgain() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        let manager = await harness.installInAppMessaging()
        let messageId = UUID()
        URLProtocolStub.handler = Self.listHandler(ids: [messageId])

        let delivered = await manager.poll()
        guard let message = delivered.first else { return XCTFail("expected a message") }

        let error = await prepareError(harness, message)
        XCTAssertEqual(error as? InAppMessages.Error, .requestFailed, "\(String(describing: error))")

        let nextStint = await manager.poll()
        XCTAssertEqual(nextStint.map(\.id), [message.id], "the message never reached the screen — deliver it again")
    }

    func test_prepare_withAnIdGalvaNeverIssued_throwsMessageNotFound() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        _ = await harness.installInAppMessaging()
        let message = InAppMessages.Message(id: "not-a-uuid", workflowType: nil, createdAt: Date())

        let error = await prepareError(harness, message)
        XCTAssertEqual(error as? InAppMessages.Error, .messageNotFound, "\(String(describing: error))")
    }

    // MARK: - Automatic presentation diagnostics

    func test_presentAutomatically_failure_logsAWarningWithTheError() async {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let harness = await SDKHarness.make()
        defer { harness.cleanup() }
        let logger = RecordingLogger()
        await harness.configure(logger: logger)
        _ = await harness.installInAppMessaging()
        let message = InAppMessages.Message(id: UUID().uuidString.lowercased(), workflowType: nil, createdAt: Date())

        await harness.core.presentAutomatically(message)

        let entry = logger.entries.first { $0.message == "in-app message not shown" }
        XCTAssertEqual(entry?.level, .warning, "a failed presentation must show at the default log level")
        XCTAssertEqual(entry?.error as? InAppMessages.Error, .noPresentingViewController)
    }

    /// What `prepareInAppMessage` threw, or `nil` if it succeeded.
    private func prepareError(_ harness: SDKHarness, _ message: InAppMessages.Message) async -> (any Error)? {
        let host = StubHost()
        do {
            _ = try await harness.core.prepareInAppMessage(message, host: host)
            return nil
        } catch {
            return error
        }
    }

    #endif

    // MARK: - Helpers

    /// Wait (bounded) until the stubbed session has received a request.
    private static func waitForRequest() async {
        for _ in 0 ..< 500 where URLProtocolStub.requests.isEmpty {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(URLProtocolStub.requests.isEmpty, "fetch should be in flight")
    }

    /// Hold the upload of `user`'s messages — as a batch flush inside an
    /// identify's emit would — until `release` opens. `reached` opens once
    /// it's held.
    private static func holdUpload(
        of user: String,
        in harness: SDKHarness
    ) async -> (reached: TestGate, release: TestGate) {
        let reached = TestGate()
        let release = TestGate()
        await harness.consumer.setBeforeConsume { messages in
            guard messages.contains(where: { $0.endUserId == user }) else { return }
            await reached.open()
            await release.wait()
        }
        return (reached, release)
    }

    /// Serves `ids` for the message list (after `blocker` is signalled, when
    /// given) and fails every other request, including resolve, with a 500.
    private nonisolated static func listHandler(
        ids: [UUID],
        blockedBy blocker: DispatchSemaphore? = nil
    ) -> URLProtocolStub.Handler {
        { request in
            guard request.url?.path == SDKConstants.communicationListPath else {
                return (URLProtocolStub.httpResponse(url: request.url!, status: 500), Data())
            }
            blocker?.wait()
            let items = ids.map { id -> [String: Any] in
                [
                    "id": id.uuidString,
                    "type": "trial-rescue-in-app",
                    "workflowType": "trial-rescue",
                    "createdAt": ISO8601DateFormatter.galva.string(from: Date()),
                ]
            }
            let body = try JSONSerialization.data(withJSONObject: [
                "success": true,
                "data": items,
                "meta": ["nextCursor": NSNull()],
            ] as [String: Any])
            return (URLProtocolStub.httpResponse(url: request.url!, status: 200), body)
        }
    }
}

#if canImport(UIKit) && canImport(WebKit)
/// A host for `prepareInAppMessage` in tests that fail before it is used.
@MainActor
private final class StubHost: InAppMessageHost {
    var webView: WKWebView? { nil }
    var safeAreaInsets: UIEdgeInsets { .zero }
    func reveal() {}
    func dismiss(reason: String?) {}
}
#endif
