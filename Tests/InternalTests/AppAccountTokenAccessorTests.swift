//
//  AppAccountTokenAccessorTests.swift
//  GalvaTests
//
//  Covers the public `AppUser.appAccountToken` accessor (the SDKCore
//  `cachedAppAccountToken` mirror it reads). The accessor returns the *resolved*
//  purchase token — the developer override from identify(userId:appAccountToken:)
//  when set, otherwise Galva's generated token (the anonymousId as a UUID) — and
//  must always equal the value `IdentityStore.purchaseAttributionToken` hands to
//  StoreKit, so a developer's own purchase reconciles to the same account as a
//  Galva-initiated one.
//
//  Fresh SDKHarness per test so the static mirror is reseeded by each configure
//  and never leaks across tests.
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class AppAccountTokenAccessorTests: XCTestCase {

    /// Letter-bearing UUID so the lowercase wire convention stays observable.
    private let override = UUID(uuidString: "B1FE821D-5597-4ABC-87B6-1F9647CFFD6E")!

    // MARK: - Generated fallback (no override)

    func test_afterConfigure_returnsGeneratedToken() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        let token = harness.core.cachedAppAccountToken
        XCTAssertNotNil(token, "The generated token must be available right after configure()")
        XCTAssertEqual(
            token,
            UUID(uuidString: harness.identity.anonymousId),
            "With no override set, the token is the anonymousId rendered as a UUID"
        )
    }

    // MARK: - Developer override

    func test_identify_withToken_returnsDeveloperToken() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "u", appAccountToken: override, traits: nil)

        XCTAssertEqual(
            harness.core.cachedAppAccountToken,
            override,
            "After identify(appAccountToken:), the accessor returns the developer's token"
        )
    }

    // MARK: - logOut clears the override

    func test_logOut_returnsFreshGeneratedToken() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "u", appAccountToken: override, traits: nil)
        XCTAssertEqual(harness.core.cachedAppAccountToken, override)

        await harness.core.logOut()

        let token = harness.core.cachedAppAccountToken
        XCTAssertNotEqual(token, override, "logOut() clears the developer override")
        XCTAssertEqual(
            token,
            UUID(uuidString: harness.identity.anonymousId),
            "After logOut() the token is the freshly-rotated anonymousId as a UUID"
        )
    }

    // MARK: - Equivalence with the StoreKit purchase token

    /// The accessor must equal the token StoreKit purchases use across every
    /// identity transition — this is the guarantee that lets a developer pass it
    /// into their own `Product.purchase(options:)` and reconcile to the same
    /// account Galva uses.
    func test_matchesPurchaseToken_acrossLifecycle() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        XCTAssertEqual(
            harness.core.cachedAppAccountToken,
            harness.identity.purchaseAttributionToken,
            "configure: mirror == purchase token"
        )

        await harness.core.identify(userId: "u", appAccountToken: override, traits: nil)
        XCTAssertEqual(
            harness.core.cachedAppAccountToken,
            harness.identity.purchaseAttributionToken,
            "identify: mirror == purchase token"
        )

        await harness.core.logOut()
        XCTAssertEqual(
            harness.core.cachedAppAccountToken,
            harness.identity.purchaseAttributionToken,
            "logOut: mirror == purchase token"
        )
    }
}
