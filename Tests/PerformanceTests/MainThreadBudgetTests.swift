//
//  MainThreadBudgetTests.swift
//  GalvaTests
//
//  The SDK's #1 performance promise: a public call must return to the host
//  app's thread in microseconds — every entry point is a fire-and-forget
//  `Task { @GalvaActor … }` enqueue (see Sources/Galva.swift), never inline
//  work. These contract tests time the SYNCHRONOUS return of each public call
//  on the main thread and fail if any starts blocking.
//
//  Companion to `PerformanceContractTests` (which already covers `track` and
//  the `identifiedUserId` sync read). Calls run against the UNCONFIGURED
//  shared singleton — exactly like the existing `track` test — so they enqueue
//  + early-return inside the actor with no network or shared-state mutation.
//  `Galva.configure` is intentionally excluded: invoking it would trigger real
//  async configuration; its one-time launch cost is covered by the demo app's
//  Layer-2 launch metric instead.
//
//  Bounds are deliberately loose — they catch orders-of-magnitude regressions
//  (someone adding sync work to a call site), not micro-jitter on slow CI.
//

import Foundation
@testable import Galva
import XCTest

/// Central perf budgets for the main-thread contract tests. The memory /
/// launch budgets for the app-process (Layer 2) live in the demo UI-test
/// target and mirror the plan's budget table.
enum PerfBudget {
    /// Generic fire-and-forget public call: enqueue a Task + return. ~µs in
    /// practice; 150µs is a loose ceiling that still catches sync work.
    static let fireAndForgetNs: Double = 150_000
}

@MainActor
final class MainThreadBudgetTests: XCTestCase {

    /// Average synchronous wall-clock per call, measured on the main thread
    /// with a warm-up pass to absorb first-call lazy init.
    private func nsPerCall(iterations: Int = 10_000, _ body: () -> Void) -> Double {
        for _ in 0..<min(iterations, 1_000) { body() }   // warm up
        let start = DispatchTime.now()
        for _ in 0..<iterations { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsed) / Double(iterations)
    }

    private func assertUnderBudget(
        _ ns: Double, _ label: String, budget: Double = PerfBudget.fireAndForgetNs,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertLessThan(
            ns, budget,
            "\(label) averaged \(Int(ns)) ns/call on the main thread — must stay under \(Int(budget)) ns (it should only enqueue a Task)",
            file: file, line: line
        )
    }

    func test_identify_returnsImmediately() {
        assertUnderBudget(nsPerCall { AppUser.identify(userId: "perf") }, "AppUser.identify")
    }

    func test_setTrait_returnsImmediately() {
        assertUnderBudget(nsPerCall { AppUser.set(.email, "perf@example.com") }, "AppUser.set(.email)")
    }

    func test_logOut_returnsImmediately() {
        // Fewer iterations — logOut rotates the anonymous id work happens async
        // inside the actor; we only time the synchronous enqueue here.
        assertUnderBudget(nsPerCall(iterations: 5_000) { AppUser.logOut() }, "AppUser.logOut")
    }

    func test_checkForMessages_returnsImmediately() {
        assertUnderBudget(nsPerCall { InAppMessages.checkForMessages() }, "InAppMessages.checkForMessages")
    }

    func test_handleOpenURL_returnsImmediately() {
        let url = URL(string: "gvperf://openCommunication?communicationId=perf")!  // swiftlint:disable:this force_unwrapping
        assertUnderBudget(nsPerCall { _ = Galva.handleOpenURL(url) }, "Galva.handleOpenURL")
    }

    func test_handleOpenURL_nonGalvaURL_returnsImmediately() {
        // The synchronous `canHandle` gate (returns false, app keeps routing)
        // must also be cheap.
        let url = URL(string: "https://example.com/whatever")!  // swiftlint:disable:this force_unwrapping
        assertUnderBudget(nsPerCall { _ = Galva.handleOpenURL(url) }, "Galva.handleOpenURL (non-gv)")
    }

    func test_registerDeviceToken_returnsImmediately() {
        let token = Data(repeating: 0xAB, count: 32)  // typical APNs token size
        assertUnderBudget(
            nsPerCall { Galva.applicationDidRegisterForRemoteNotificationsWithDeviceToken(token) },
            "applicationDidRegisterForRemoteNotificationsWithDeviceToken"
        )
    }
}
