//
//  AppUserSetTraitTests.swift
//  GalvaTests
//
//  Covers the public `AppUser.set(.email, …)` (and friends) path. Three
//  layers:
//
//    1. Trait shape — the typed attributes (`AppUserTraits.Email`,
//       `.firstName`, …) resolve to the `BuiltInTraitKey.*` wire keys.
//       Compile-time check that the public dot-shorthand stays in sync with
//       the centralized registry.
//
//    2. Trait construction — building `[attribute.attributeName:
//       AnyJSONValue(value)]` (exactly what `AppUser.set` does internally)
//       produces the expected `[String: AnyJSONValue]` dictionary.
//
//    3. End-to-end through identify — feeding that dictionary through
//       `SDKCore.identify(…)` delivers the email to the consumer with the
//       right wire key, alongside the auto-attached device traits.
//
//  `AppUser.set` itself routes through `SDKCore.shared`, which the harness
//  can't intercept; replicating its trait construction against the
//  harness's `SDKCore` instance gives an isolated test of the same
//  contract without polluting the production singleton.
//

import Foundation
@testable import Galva
import XCTest

@GalvaActor
final class AppUserSetTraitTests: XCTestCase {

    // MARK: - Trait shape (compile-time contract)

    func test_emailAttribute_mapsToBuiltInTraitKey() async {
        XCTAssertEqual(AppUserTraits.Email().attributeName, BuiltInTraitKey.email)
    }

    func test_allBuiltInAttributes_mapToBuiltInTraitKeys() async {
        XCTAssertEqual(AppUserTraits.Email().attributeName,              BuiltInTraitKey.email)
        XCTAssertEqual(AppUserTraits.FullName().attributeName,           BuiltInTraitKey.fullName)
        XCTAssertEqual(AppUserTraits.FirstName().attributeName,          BuiltInTraitKey.firstName)
        XCTAssertEqual(AppUserTraits.LastName().attributeName,           BuiltInTraitKey.lastName)
        XCTAssertEqual(AppUserTraits.Country().attributeName,            BuiltInTraitKey.country)
        XCTAssertEqual(AppUserTraits.Timezone().attributeName,           BuiltInTraitKey.timezone)
        XCTAssertEqual(AppUserTraits.LanguageCode().attributeName,       BuiltInTraitKey.languageCode)
        XCTAssertEqual(AppUserTraits.TotalLifetimeValue().attributeName, BuiltInTraitKey.totalLifetimeValue)
    }

    // MARK: - Trait construction (mirrors AppUser.set internals)

    func test_setEmail_buildsCorrectTraitDict() async {
        let trait = AppUser_setTraitDict(.email, "peter@example.com")
        XCTAssertEqual(trait[BuiltInTraitKey.email], .string("peter@example.com"))
        XCTAssertEqual(trait.count, 1, "set() must construct exactly one trait")
    }

    func test_setTotalLifetimeValue_carriesDoubleAsDouble() async {
        let trait = AppUser_setTraitDict(.totalLifetimeValue, 199.99)
        XCTAssertEqual(trait[BuiltInTraitKey.totalLifetimeValue], .double(199.99))
    }

    // MARK: - End-to-end: email reaches the identify payload

    func test_setEmail_reachesIdentifyConsumer() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.consumer.reset()

        let trait = AppUser_setTraitDict(.email, "peter@example.com")
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: trait)

        let messages = await harness.consumer.allMessages
        guard let identifyTraits = messages.first?.identifyTraits else {
            return XCTFail("Expected an identify message with traits")
        }
        XCTAssertEqual(
            identifyTraits[BuiltInTraitKey.email],
            .string("peter@example.com"),
            "Email trait must reach the identify payload with the $gv_email wire key"
        )
    }

    func test_setEmail_preservesEmailAlongsideAutoAttachedDeviceTraits() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.consumer.reset()

        let trait = AppUser_setTraitDict(.email, "peter@example.com")
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: trait)

        let identifyTraits = await harness.consumer.allMessages.first?.identifyTraits
        XCTAssertEqual(identifyTraits?[BuiltInTraitKey.email], .string("peter@example.com"))
        XCTAssertNotNil(identifyTraits?[BuiltInTraitKey.timezone],
                        "Device timezone is still auto-attached when email is set")
        XCTAssertNotNil(identifyTraits?[BuiltInTraitKey.languageCode],
                        "Device languageCode is still auto-attached when email is set")
    }

    func test_setEmail_doesNotChangeIdentifiedUserId() async {
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }

        await harness.core.identify(userId: "stable_user", appAccountToken: nil, traits: nil)
        await harness.consumer.reset()

        let trait = AppUser_setTraitDict(.email, "peter@example.com")
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: trait)

        let msg = await harness.consumer.allMessages.first
        XCTAssertEqual(msg?.endUserId, "stable_user",
                       "set(.email) must not unbind the current user")
        XCTAssertEqual(msg?.identifyTraits?[BuiltInTraitKey.email], .string("peter@example.com"))
    }

    func test_setEmail_invalidAddress_isDropped() async {
        // The same EmailValidator gate that protects registerEmail also runs
        // inside identify, so an invalid `$gv_email` trait never reaches the
        // server — even when the caller supplied it via AppUser.set(.email).
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.consumer.reset()

        let trait = AppUser_setTraitDict(.email, "not-an-email")
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: trait)

        let identifyTraits = await harness.consumer.allMessages.first?.identifyTraits
        XCTAssertNil(identifyTraits?[BuiltInTraitKey.email],
                     "Invalid email must be dropped before the identify is emitted")
    }

    // MARK: - Helper

    /// Reproduces the trait-dict construction performed by
    /// `AppUser.set<A: AppUserAttribute>(_:_:)`. The public setter routes
    /// through `SDKCore.shared`, which the test harness can't intercept;
    /// the same dict driven through `harness.core.identify(…)` exercises the
    /// identical wire contract end-to-end.
    private func AppUser_setTraitDict<A: AppUserAttribute>(
        _ attribute: A, _ value: A.Value
    ) -> [String: AnyJSONValue] {
        [attribute.attributeName: AnyJSONValue(value)]
    }
}
