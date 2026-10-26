//
//  AppLifecycleObserverTests.swift
//  GalvaTests
//
//  Pins what wakes the SDK: the cold start, then every didBecomeActive —
//  including the ones after Control Center, a Face ID / permission prompt or
//  a call banner, which never background the app. Each is a chance to
//  refresh in-app messages. Driven on a private NotificationCenter with a
//  stand-in name so it runs under `swift test` on macOS.
//

import Foundation
@testable import Galva
import XCTest

/// Counts `onForeground` calls. Lock-protected: the callback is `@Sendable`.
private final class ForegroundCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

@MainActor
final class AppLifecycleObserverTests: XCTestCase {

    private let center = NotificationCenter()
    private let didBecomeActive = Notification.Name("test.didBecomeActive")
    private let counter = ForegroundCounter()

    private func makeObserver(observesActivation: Bool = true) -> AppLifecycleObserver {
        let counter = self.counter
        return AppLifecycleObserver(
            center: center,
            didBecomeActive: observesActivation ? didBecomeActive : nil,
            onForeground: { counter.increment() }
        )
    }

    /// Let queued main-queue work (notification blocks, the deferred
    /// cold-start event) run.
    private func drainMain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
        }
    }

    private func becomeActive() async {
        center.post(name: didBecomeActive, object: nil)
        await drainMain()
    }

    func test_start_firesTheColdStartEvent() async {
        let observer = makeObserver()
        observer.start()
        await drainMain()
        XCTAssertEqual(counter.count, 1)
    }

    func test_everyActivation_fires() async {
        // A return from the background and a system overlay closing both
        // arrive as didBecomeActive; each one is a chance to refresh.
        let observer = makeObserver()
        observer.start()
        await drainMain()

        await becomeActive()
        await becomeActive()

        XCTAssertEqual(counter.count, 3, "cold start plus one per activation")
    }

    func test_start_isIdempotent() async {
        let observer = makeObserver()
        observer.start()
        observer.start()
        await drainMain()
        XCTAssertEqual(counter.count, 1)

        await becomeActive()
        XCTAssertEqual(counter.count, 2, "one registration, one callback per activation")
    }

    func test_stop_removesObservers() async {
        let observer = makeObserver()
        observer.start()
        await drainMain()
        observer.stop()

        await becomeActive()

        XCTAssertEqual(counter.count, 1)
    }

    func test_withoutActivationSignal_firesColdStartOnly() async {
        // No UIApplication (macOS): only the cold-start event.
        let observer = makeObserver(observesActivation: false)
        observer.start()
        await drainMain()

        await becomeActive()

        XCTAssertEqual(counter.count, 1)
    }
}
