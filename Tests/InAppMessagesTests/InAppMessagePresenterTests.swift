//
//  InAppMessagePresenterTests.swift
//  GalvaTests
//
//  The UIKit presenter:
//    • `show` runs one call at a time: a second call for the message in
//      flight is a no-op, another message waits its turn
//    • `show` never waits on UIKit forever — not on a host mid-transition,
//      not on a `present` completion that never fires — and a sheet UIKit
//      never presented leaves its message deliverable
//    • a sheet that leaves the screen without the SDK dismissing it is
//      reported, and forgotten
//    • with no scene given, it presents on an app window scene, preferring
//      a foreground-active one with a key window
//
//  Runs on the iOS Simulator. In the test runner UIKit never finishes a
//  presentation (see `InAppMessagePresentationTestSupport`) — the same as
//  UIKit refusing one — so every `show` here ends in
//  `.noPresentingViewController` once the presenter gives up.
//

import Foundation
@testable import Galva
import XCTest
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

@MainActor
final class InAppMessagePresenterTests: XCTestCase {

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true }
        windows.removeAll()
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    // MARK: - One show at a time

    func test_show_sameMessageTwice_presentsItOnce() async {
        let (presenter, harness) = await makePresenter(presentTimeout: 1)
        defer { harness.cleanup() }
        let (scene, root) = makeWindow()
        let message = makeInAppMessage()

        let first = ShowCall(presenter, message, scene)
        let second = ShowCall(presenter, message, scene)

        let presented = await waitUntil(within: 3) { root.presentedViewController is InAppMessageViewController }
        XCTAssertTrue(presented, "the first show should reach present")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(InAppMessageStubServer.resolvedIds, [message.id], "the second show must not resolve or present again")
        XCTAssertTrue(second.isFinished, "a show for the message in flight returns at once")
        XCTAssertNil(second.error)

        let firstFinished = await waitUntil(within: 3) { first.isFinished }
        XCTAssertTrue(firstFinished)
    }

    func test_show_anotherMessage_waitsForTheOneInFlight() async {
        let (presenter, harness) = await makePresenter(presentTimeout: 1)
        defer { harness.cleanup() }
        let (scene, _) = makeWindow()
        let messageA = makeInAppMessage()
        let messageB = makeInAppMessage()

        let showA = ShowCall(presenter, messageA, scene)
        let showB = ShowCall(presenter, messageB, scene)

        let presentingA = await waitUntil(within: 3) { presenter.viewController?.messageId == messageA.id }
        XCTAssertTrue(presentingA, "A should reach present")
        XCTAssertTrue(
            presenter.webView?.navigationDelegate is InAppMessageNavigationPolicy,
            "the UIKit sheet uses the shared navigation policy"
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(InAppMessageStubServer.resolvedIds, [messageA.id], "B must not start while A is in flight")

        let bothFinished = await waitUntil(within: 6) { showA.isFinished && showB.isFinished }
        XCTAssertTrue(bothFinished, "B runs once A finishes")
        XCTAssertEqual(InAppMessageStubServer.resolvedIds, [messageA.id, messageB.id])
    }

    // MARK: - Bounded waits on UIKit

    func test_show_whenUIKitNeverFinishesPresenting_givesUpAndForgetsTheSheet() async {
        let (presenter, harness) = await makePresenter(presentTimeout: 0.5)
        defer { harness.cleanup() }
        let (scene, _) = makeWindow()
        let message = makeInAppMessage()

        let call = ShowCall(presenter, message, scene)

        let finished = await waitUntil(within: 3) { call.isFinished }
        XCTAssertTrue(finished, "show must not wait forever for UIKit's present completion")
        XCTAssertEqual(call.error as? InAppMessageError, .noPresentingViewController, "\(String(describing: call.error))")
        XCTAssertNil(presenter.viewController)
        let active = await harness.core.inAppMessageManager?.currentActiveMessageId()
        XCTAssertNil(active)
        let shown = await harness.core.inAppMessageManager?.hasPresented(messageId: message.id)
        XCTAssertEqual(shown, false, "UIKit never presented it — the message stays deliverable")
    }

    func test_show_whenUIKitNeverFinishesPresenting_deliversTheMessageAgainNextStint() async {
        let messageId = UUID()
        let (presenter, harness) = await makePresenter(presentTimeout: 0.5, listing: [messageId])
        defer { harness.cleanup() }
        harness.core.presenter = presenter
        let (scene, _) = makeWindow()
        let manager = await harness.core.inAppMessageManager

        let delivered = await manager?.poll() ?? []
        XCTAssertEqual(delivered.map(\.id), [messageId.uuidString.lowercased()])
        guard let message = delivered.first else { return }
        do {
            try await harness.core.showInAppMessage(message, in: scene)
            XCTFail("show must throw when UIKit never presents the sheet")
        } catch {
            XCTAssertEqual(error as? InAppMessages.Error, .noPresentingViewController, "\(error)")
        }

        let nextStint = await manager?.poll() ?? []
        XCTAssertEqual(nextStint.map(\.id), [message.id], "the sheet never reached the screen — deliver it again")
    }

    func test_show_whenTheTopViewControllerIsMidTransition_doesNotPresentOnIt() async {
        let (presenter, harness) = await makePresenter(presentTimeout: 0.5)
        defer { harness.cleanup() }
        let (scene, root) = makeWindow()
        // The app's own sheet, still animating in (it never finishes here).
        let appSheet = UIViewController()
        root.present(appSheet, animated: true)
        let message = makeInAppMessage()

        let call = ShowCall(presenter, message, scene)

        let finished = await waitUntil(within: 3) { call.isFinished }
        XCTAssertTrue(finished, "show must not wait forever on a host UIKit won't present on")
        XCTAssertEqual(call.error as? InAppMessageError, .noPresentingViewController, "\(String(describing: call.error))")
        XCTAssertNil(appSheet.presentedViewController)
        let shown = await harness.core.inAppMessageManager?.hasPresented(messageId: message.id)
        XCTAssertEqual(shown, false, "nothing was presented — the message stays deliverable")
    }

    // MARK: - Removed without the SDK

    func test_viewController_removedWithoutTheSDK_reportsIt() {
        let delegate = RecordingDelegate()
        let vc = makeViewController(delegate: delegate)

        // Not presented by anything any more (the app dismissed it, or the
        // view controller under it).
        vc.viewDidDisappear(false)

        XCTAssertEqual(delegate.removed.count, 1)
    }

    func test_viewController_disappearingButStillPresented_doesNotReportIt() {
        let delegate = RecordingDelegate()
        let vc = makeViewController(delegate: delegate)
        let (_, root) = makeWindow()
        root.present(vc, animated: false)
        XCTAssertNotNil(vc.presentingViewController)

        // Covered by something presented over it — still on its presenter.
        vc.viewDidDisappear(false)

        XCTAssertEqual(delegate.removed.count, 0)
    }

    // MARK: - Scene choice

    func test_preferredScene_skipsScenesOnAnExternalDisplay() {
        let external = StubScene(isApplicationWindow: false, isForegroundActive: true, hasKeyWindow: true)
        let app = StubScene(isApplicationWindow: true, isForegroundActive: true, hasKeyWindow: true)
        XCTAssertEqual(StubScene.pick([external, app]), app)
        XCTAssertNil(StubScene.pick([external]))
    }

    func test_preferredScene_prefersAnActiveSceneWithAKeyWindow() {
        let activeWithoutKey = StubScene(isApplicationWindow: true, isForegroundActive: true, hasKeyWindow: false)
        let activeWithKey = StubScene(isApplicationWindow: true, isForegroundActive: true, hasKeyWindow: true)
        XCTAssertEqual(StubScene.pick([activeWithoutKey, activeWithKey]), activeWithKey)
    }

    func test_preferredScene_fallsBackToAnyAppScene() {
        let external = StubScene(isApplicationWindow: false, isForegroundActive: true, hasKeyWindow: true)
        let inactive = StubScene(isApplicationWindow: true, isForegroundActive: false, hasKeyWindow: false)
        let active = StubScene(isApplicationWindow: true, isForegroundActive: true, hasKeyWindow: false)
        XCTAssertEqual(StubScene.pick([external, inactive]), inactive)
        XCTAssertEqual(StubScene.pick([inactive, active]), active)
    }

    // MARK: - Helpers

    private func makePresenter(
        presentTimeout: TimeInterval,
        listing: [UUID] = []
    ) async -> (InAppMessagePresenter, SDKHarness) {
        URLProtocolStub.reset()
        URLProtocolStub.handler = InAppMessageStubServer.handler(html: "<html><body></body></html>", listing: listing)
        let harness = await SDKHarness.makeConfigured()
        let manager = await harness.installInAppMessaging()
        guard let bundleCache = await harness.core.bundleCache else {
            preconditionFailure("installInAppMessaging sets a bundle cache")
        }
        let presenter = InAppMessagePresenter(
            messageManager: manager,
            identity: harness.identity,
            bundleCache: bundleCache,
            storeKitPrefetcher: nil,
            logger: SilentLogger()
        )
        presenter.presentTimeout = presentTimeout
        return (presenter, harness)
    }

    /// A key window and its root view controller, plus the window's scene.
    private func makeWindow() -> (UIWindowScene, UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        windows.append(window)
        guard let scene = window.windowScene else {
            preconditionFailure("a visible window has a scene")
        }
        return (scene, root)
    }

    private func makeViewController(delegate: RecordingDelegate) -> InAppMessageViewController {
        let vc = InAppMessageViewController(
            webView: WKWebView(),
            bundleURL: URL(fileURLWithPath: "/tmp/bundle.html"),
            messageId: "m1",
            logger: SilentLogger()
        )
        vc.delegate = delegate
        vc.loadViewIfNeeded()
        return vc
    }
}

/// A `show` call running in its own task, and how it ended.
@MainActor
private final class ShowCall {
    private(set) var isFinished = false
    private(set) var error: (any Error)?

    init(_ presenter: InAppMessagePresenter, _ message: InAppMessages.Message, _ scene: UIWindowScene) {
        Task { @MainActor in
            do {
                try await presenter.show(message: message, in: scene)
            } catch {
                self.error = error
            }
            self.isFinished = true
        }
    }
}

@MainActor
private final class RecordingDelegate: InAppMessageViewControllerDelegate {
    private(set) var removed: [InAppMessageViewController] = []

    func inAppMessageViewControllerDidDisappear(_ controller: InAppMessageViewController) {
        removed.append(controller)
    }
}

private struct StubScene: Equatable {
    let id = UUID()
    let isApplicationWindow: Bool
    let isForegroundActive: Bool
    let hasKeyWindow: Bool

    @MainActor
    static func pick(_ scenes: [StubScene]) -> StubScene? {
        InAppMessagePresenter.preferredScene(among: scenes) { scene in
            InAppMessagePresenter.SceneTraits(
                isApplicationWindow: scene.isApplicationWindow,
                isForegroundActive: scene.isForegroundActive,
                hasKeyWindow: scene.hasKeyWindow
            )
        }
    }
}

#endif
