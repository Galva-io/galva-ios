//
//  IdentityStoreTokenTests.swift
//  GalvaTests
//
//  Covers the new appAccountToken storage + the purchaseAttributionToken
//  fallback chain (override → anonymousId-as-UUID → fresh UUID).
//

import Foundation
@testable import Galva
import XCTest

final class IdentityStoreTokenTests: XCTestCase {

    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "co.galva.test.\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Override storage

    func test_setAppAccountToken_persistsAcrossInstances() async {
        let token = UUID()
        let name = suiteName!
        // Write
        await Self.runOnActor(suiteName: name) { store in
            store.setAppAccountToken(token)
            XCTAssertEqual(store.appAccountToken, token)
        }
        // Read back from a fresh instance backed by the same defaults
        await Self.runOnActor(suiteName: name) { store in
            XCTAssertEqual(store.appAccountToken, token,
                           "token must survive process restart")
        }
    }

    func test_setAppAccountToken_nilClearsStorage() async {
        await Self.runOnActor(suiteName: suiteName) { store in
            store.setAppAccountToken(UUID())
            store.setAppAccountToken(nil)
            XCTAssertNil(store.appAccountToken)
        }
    }

    // MARK: - purchaseAttributionToken fallback

    func test_purchaseAttributionToken_returnsOverride_whenSet() async {
        let override = UUID()
        await Self.runOnActor(suiteName: suiteName) { store in
            store.setAppAccountToken(override)
            XCTAssertEqual(store.purchaseAttributionToken, override)
        }
    }

    func test_purchaseAttributionToken_fallsBackToAnonymousId_whenNoOverride() async {
        await Self.runOnActor(suiteName: suiteName) { store in
            let expected = UUID(uuidString: store.anonymousId)
            XCTAssertEqual(store.purchaseAttributionToken, expected,
                           "anonymousId is a UUIDv7 and must parse as a UUID")
        }
    }

    // MARK: - logout / rotation clears override

    func test_rotateAnonymousId_alsoClearsAppAccountToken() async {
        await Self.runOnActor(suiteName: suiteName) { store in
            store.setAppAccountToken(UUID())
            store.rotateAnonymousId()
            XCTAssertNil(store.appAccountToken,
                         "token must not carry across users — logout clears it")
        }
    }

    // MARK: - Helper

    /// Build an `IdentityStore` on the GalvaActor (it requires actor
    /// isolation) without sending a non-`Sendable` `UserDefaults` across
    /// the actor boundary. The suite name is a string and crosses safely.
    /// `body` is the trailing-closure arg so callers can write
    /// `Self.runOnActor(suiteName: name) { store in … }`.
    @GalvaActor
    private static func runOnActor(
        suiteName: String,
        _ body: @GalvaActor (IdentityStore) -> Void
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("failed to allocate UserDefaults suite")
        }
        let store = IdentityStore(defaults: defaults)
        body(store)
    }
}
