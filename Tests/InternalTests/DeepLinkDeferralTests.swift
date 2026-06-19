//
//  DeepLinkDeferralTests.swift
//  GalvaTests
//
//  Covers deferred deep links. `openCommunication` resolves a user-targeted
//  communication, so it can't run until the user is identified. A link that
//  arrives before `configure()` / `identify()` must be held and replayed once
//  identity is available:
//    • deferred when unconfigured
//    • deferred when configured but still anonymous
//    • the anonymous seed/trait `identify(userId: nil)` must NOT flush it
//    • a real `identify(userId:)` replays + clears it
//    • already-identified → dispatched immediately, never deferred
//    • latest-wins while deferred
//
//  Uses the SDKHarness (a fresh, non-singleton SDKCore) so identity state
//  never leaks across tests. The in-app presentation itself is a no-op here
//  (no message manager is wired), so these assert the defer → replay state
//  machine via the readable `deferredDeepLink`.
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class DeepLinkDeferralTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func openCommunication(_ id: String) -> DeepLink {
        .openCommunication(communicationId: id, parameters: ["communicationId": id])
    }

    func test_deferred_whenNotConfigured() async {
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c1"))
        XCTAssertEqual(harness.core.deferredDeepLink, openCommunication("c1"),
                       "a link before configure() must be deferred")
    }

    func test_deferred_whenConfiguredButAnonymous() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c1"))
        XCTAssertEqual(harness.core.deferredDeepLink, openCommunication("c1"),
                       "anonymous user → defer until identify")
    }

    func test_anonymousIdentify_doesNotFlush() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c1"))
        // A trait-only / anonymous identify (no userId) must not satisfy the
        // identity requirement — the link stays deferred.
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: ["k": .string("v")])
        XCTAssertEqual(harness.core.deferredDeepLink, openCommunication("c1"),
                       "anonymous identify must not resolve an identity-requiring link")
    }

    func test_resolvesAfterIdentify() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c1"))
        XCTAssertNotNil(harness.core.deferredDeepLink)

        await harness.core.identify(userId: "u1", appAccountToken: nil, traits: nil)
        XCTAssertNil(harness.core.deferredDeepLink,
                     "identify(userId:) should replay + clear the deferred link")
    }

    func test_notDeferred_whenAlreadyIdentified() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "u1", appAccountToken: nil, traits: nil)
        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c1"))
        XCTAssertNil(harness.core.deferredDeepLink,
                     "identified user → dispatch now, never defer")
    }

    func test_latestWins_whileDeferred() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c1"))
        await harness.core.handleOpenURL(url("gvtest://openCommunication?communicationId=c2"))
        XCTAssertEqual(harness.core.deferredDeepLink, openCommunication("c2"),
                       "a newer deferred link replaces an older unresolved one")
    }
}
