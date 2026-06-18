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

    // MARK: - Foundation-bridged values (regression cover for QA's lost-email report)

    func test_setBulk_NSString_isAcceptedAsEmailTrait() async {
        // Reproduces the QA-reported case: an `Any` value sourced from
        // UserDefaults that arrives as `NSString`. The lenient bulk overload
        // routes through `AnyJSONValue.coercing(_:)`, which already bridges
        // `NSString` → `String` → `.string` — so the email reaches identify
        // even though the host never converted to Swift `String` first.
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.consumer.reset()

        let attributes: [String: Any] = [
            BuiltInTraitKey.email: NSString(string: "peter@example.com"),
        ]
        let coerced = AnyJSONValue.coercing(dictionary: attributes)
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: coerced)

        let identifyTraits = await harness.consumer.allMessages.first?.identifyTraits
        XCTAssertEqual(
            identifyTraits?[BuiltInTraitKey.email],
            .string("peter@example.com"),
            "NSString email must bridge through coercion and reach identify"
        )
    }

    func test_setBulk_NSNumber_isAcceptedAsTypedTrait() async {
        // `NSNumber` is what a JSON-decoded integer / double / bool arrives
        // as on the wire. The coercion path distinguishes bool from int from
        // double via CFBoolean / objCType so trait shape is preserved.
        let harness = await SDKHarness.makeConfigured()
        defer { harness.cleanup() }
        await harness.consumer.reset()

        let attributes: [String: Any] = [
            BuiltInTraitKey.totalLifetimeValue: NSNumber(value: 49.99),
            "habit_streak": NSNumber(value: 13),
            "is_pro": NSNumber(value: true),
        ]
        let coerced = AnyJSONValue.coercing(dictionary: attributes)
        await harness.core.identify(userId: nil, appAccountToken: nil, traits: coerced)

        let traits = await harness.consumer.allMessages.first?.identifyTraits
        XCTAssertEqual(traits?[BuiltInTraitKey.totalLifetimeValue], .double(49.99))
        XCTAssertEqual(traits?["habit_streak"], .int(13))
        XCTAssertEqual(traits?["is_pro"], .bool(true),
                       "NSNumber-as-CFBoolean must not silently collapse to .int(1)")
    }

    func test_coercion_dropsNonJSONValuesSilently() async {
        // The bulk setter's contract: non-JSON entries are dropped, the rest
        // survives. A bug in the host that puts a closure / arbitrary class
        // into the dict shouldn't take the whole identify down with it.
        final class Unrepresentable {}
        let attributes: [String: Any] = [
            BuiltInTraitKey.email: NSString(string: "p@x.co"),
            "garbage": Unrepresentable(),
        ]
        let coerced = AnyJSONValue.coercing(dictionary: attributes)
        XCTAssertEqual(coerced[BuiltInTraitKey.email], .string("p@x.co"))
        XCTAssertNil(coerced["garbage"], "non-JSON entries must be dropped, not crash")
        XCTAssertEqual(coerced.count, 1)
    }

    func test_coercion_handlesNestedNSDictionaryAndNSArray() async {
        // Foundation collections sourced from JSON arrive as NSDictionary /
        // NSArray. The recursive coercer flattens them into `.object` /
        // `.array` of coerced values.
        let nested: [String: Any] = [
            "preferences": NSDictionary(dictionary: [
                "theme": NSString(string: "dark"),
                "fontSize": NSNumber(value: 14),
            ]),
            "tags": NSArray(array: [NSString(string: "vip"), NSString(string: "beta")]),
        ]
        let coerced = AnyJSONValue.coercing(dictionary: nested)

        guard case .object(let prefs) = coerced["preferences"] else {
            return XCTFail("nested NSDictionary must become .object")
        }
        XCTAssertEqual(prefs["theme"], .string("dark"))
        XCTAssertEqual(prefs["fontSize"], .int(14))

        guard case .array(let tags) = coerced["tags"] else {
            return XCTFail("nested NSArray must become .array")
        }
        XCTAssertEqual(tags, [.string("vip"), .string("beta")])
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
