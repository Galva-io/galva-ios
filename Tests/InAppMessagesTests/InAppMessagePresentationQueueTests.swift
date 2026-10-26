//
//  InAppMessagePresentationQueueTests.swift
//  GalvaTests
//
//  `InAppMessagePresentationQueue` runs presentations one at a time, in
//  call order. A call for a message already queued or running is dropped;
//  one that fails doesn't hold up the next.
//

import Foundation
@testable import Galva
import XCTest

@MainActor
final class InAppMessagePresentationQueueTests: XCTestCase {

    func test_runsOneAtATime_inCallOrder() async {
        let queue = InAppMessagePresentationQueue()
        let log = Log()
        let gate = TestGate()

        let a = Task { await queue.run(id: "a") { log.append("a start"); await gate.wait(); log.append("a end") } }
        let b = Task { await queue.run(id: "b") { log.append("b") } }
        let c = Task { await queue.run(id: "c") { log.append("c") } }
        await settle()
        XCTAssertEqual(log.entries, ["a start"], "b and c wait for a")

        await gate.open()
        _ = await (a.value, b.value, c.value)
        XCTAssertEqual(log.entries, ["a start", "a end", "b", "c"])
    }

    func test_callForAMessageQueuedOrRunning_isDropped() async {
        let queue = InAppMessagePresentationQueue()
        let log = Log()
        let gate = TestGate()

        let a = Task { await queue.run(id: "a") { log.append("a"); await gate.wait() } }
        let b = Task { await queue.run(id: "b") { log.append("b") } }
        await settle()
        let runningAgain = await queue.run(id: "a") { log.append("a again") }
        let queuedAgain = await queue.run(id: "b") { log.append("b again") }
        XCTAssertFalse(runningAgain)
        XCTAssertFalse(queuedAgain)

        await gate.open()
        let (ranA, ranB) = await (a.value, b.value)
        XCTAssertTrue(ranA)
        XCTAssertTrue(ranB)
        XCTAssertEqual(log.entries, ["a", "b"])
    }

    func test_messageCanRunAgain_onceItsCallFinished() async {
        let queue = InAppMessagePresentationQueue()
        let log = Log()

        await queue.run(id: "a") { log.append("a") }
        XCTAssertFalse(queue.contains("a"))
        let ranAgain = await queue.run(id: "a") { log.append("a") }

        XCTAssertTrue(ranAgain)
        XCTAssertEqual(log.entries, ["a", "a"])
    }

    func test_aFailedCall_doesNotHoldUpTheNext() async {
        let queue = InAppMessagePresentationQueue()
        let log = Log()
        let gate = TestGate()

        let a = Task { try await queue.run(id: "a") { await gate.wait(); throw Failure() } }
        let b = Task { await queue.run(id: "b") { log.append("b") } }
        await settle()
        await gate.open()

        do {
            _ = try await a.value
            XCTFail("a's error should reach its caller")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        let ranB = await b.value
        XCTAssertTrue(ranB)
        XCTAssertEqual(log.entries, ["b"])
        XCTAssertFalse(queue.contains("a"))
    }

    /// Let the tasks above reach the queue.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

private struct Failure: Error {}

@MainActor
private final class Log {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
