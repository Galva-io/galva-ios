//
//  InAppMessageDeliveryTests.swift
//  GalvaTests
//
//  `InAppMessageDelivery` is `.automatic` presentation: it presents every
//  published message, one at a time, in order.
//

import Foundation
@_spi(Testing) @testable import Galva
import XCTest

/// Records presentations; runs on the main actor.
@MainActor
private final class Recorder {
    var presented: [String] = []
    var concurrent = 0
    var maxConcurrent = 0
}

@MainActor
final class InAppMessageDeliveryTests: XCTestCase {

    private func message(_ id: String) -> InAppMessages.Message {
        InAppMessages.Message(id: id, workflowType: .trialRescue, createdAt: Date())
    }

    /// Polls until `condition` holds or about two seconds pass.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func test_presentsEveryMessage_inOrder() async {
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(messages: messages) { message in
            recorder.presented.append(message.id)
        }
        defer { delivery.stop() }

        publish.yield(message("a"))
        publish.yield(message("b"))

        let presented = await eventually { recorder.presented == ["a", "b"] }
        XCTAssertTrue(presented, "got \(recorder.presented)")
    }

    func test_presentsOneAtATime() async {
        // The next message waits until the current presentation returns,
        // so two presentations never overlap.
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(messages: messages) { message in
            recorder.concurrent += 1
            recorder.maxConcurrent = max(recorder.maxConcurrent, recorder.concurrent)
            try? await Task.sleep(nanoseconds: 30_000_000)
            recorder.presented.append(message.id)
            recorder.concurrent -= 1
        }
        defer { delivery.stop() }

        publish.yield(message("a"))
        publish.yield(message("b"))
        publish.yield(message("c"))

        let presented = await eventually { recorder.presented == ["a", "b", "c"] }
        XCTAssertTrue(presented, "got \(recorder.presented)")
        XCTAssertEqual(recorder.maxConcurrent, 1)
    }

    func test_start_isIdempotent() async {
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let (otherMessages, otherPublish) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(messages: messages) { message in
            recorder.presented.append(message.id)
        }
        // A second start must not replace the first subscription.
        delivery.start(messages: otherMessages) { message in
            recorder.presented.append("other-\(message.id)")
        }
        defer { delivery.stop() }

        publish.yield(message("a"))
        otherPublish.yield(message("b"))

        let presented = await eventually { recorder.presented == ["a"] }
        XCTAssertTrue(presented, "got \(recorder.presented)")
    }
}
