//
//  InAppMessageStreamTests.swift
//  GalvaTests
//
//  Pins the main-actor delivery contract of the in-app message stream:
//  `InAppMessageStream` is `@MainActor` and `InAppMessages.messages` is
//  `@MainActor`, so a consumer that iterates from a MainActor context
//  receives each message on the main thread and can drive UI in the loop
//  body without a manual hop.
//
//  (AsyncStream resumes on the *consumer's* executor — these tests verify
//  the SDK's documented MainActor-isolated consumption lands on main.)
//

import Foundation
@testable import Galva
import XCTest

/// Synchronous main-thread probe. `Thread.isMainThread` is unavailable from
/// an async context under Swift 6 strict concurrency, but it's valid inside a
/// plain synchronous function — and when that function is called from a
/// `@MainActor` loop body it runs on the main thread, so the result reflects
/// the consumer's executor.
private func runningOnMainThread() -> Bool { Thread.isMainThread }

@MainActor
final class InAppMessageStreamTests: XCTestCase {

    func test_messages_deliveredOnMainThread_toMainActorConsumer() async {
        let stream = InAppMessageStream()
        let consumer = stream.makeStream()

        let result = Result()
        let task = Task { @MainActor in
            for await _ in consumer {
                // The crux: this loop body runs on the consumer's executor.
                // The consumer is MainActor → must be the main thread.
                // `Thread.isMainThread` is read through a synchronous helper
                // (it's unavailable directly from an async context under
                // Swift 6 strict concurrency).
                result.wasMainThread = runningOnMainThread()
                result.received = true
                break
            }
        }

        // `makeStream()` registers the subscriber via a MainActor hop, so the
        // first yields may land before registration completes. Yield in a loop
        // (interleaving via `Task.yield()`) until the consumer receives — this
        // removes the registration race without depending on timing.
        let sample = InAppMessages.Message(
            id: "00000000-0000-0000-0000-000000000001",
            workflowType: .trialRescue,
            createdAt: Date(timeIntervalSince1970: 0),
            rawType: "trial-rescue-in-app"
        )
        var attempts = 0
        while !result.received && attempts < 500 {
            stream.yield(sample)
            await Task.yield()
            attempts += 1
        }
        task.cancel()

        XCTAssertTrue(result.received, "consumer should have received the yielded message")
        XCTAssertTrue(result.wasMainThread,
                      "a MainActor consumer must receive messages on the main thread")
    }

    func test_terminateAll_finishesConsumers() async {
        let stream = InAppMessageStream()
        let consumer = stream.makeStream()

        let finished = Box()
        let task = Task { @MainActor in
            for await _ in consumer { /* drain */ }
            finished.value = true   // loop ends only when the stream finishes
        }

        // Let the subscriber register, then finish all consumers.
        await Task.yield()
        await Task.yield()
        stream.terminateAll()

        // The consumer's `for await` should complete.
        var attempts = 0
        while !finished.value && attempts < 500 {
            await Task.yield()
            attempts += 1
        }
        task.cancel()
        XCTAssertTrue(finished.value, "terminateAll() must finish active consumer iterations")
    }

    // Both fields live on the MainActor (the test + consumer task are both
    // MainActor-isolated), so a plain class is race-free here.
    @MainActor private final class Result {
        var received = false
        var wasMainThread = false
    }

    @MainActor private final class Box {
        var value = false
    }
}
