//
//  InAppMessageDeliveryTests.swift
//  GalvaTests
//
//  `InAppMessageDelivery` puts each published message on screen the way
//  `configure(…, inAppMessages:)` asked: the SDK presents it in `.automatic`
//  mode, the app's handler gets it in `.manual` mode. Messages go one at a
//  time, in order.
//

import Foundation
@testable import Galva
import XCTest

/// Records deliveries; the handlers run on the main actor.
@MainActor
private final class Recorder {
    var automatic: [String] = []
    var manual: [String] = []
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

    func test_automatic_presentsEveryMessage() async {
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(.automatic, messages: messages, presentAutomatically: { message in
            recorder.automatic.append(message.id)
        })
        defer { delivery.stop() }

        publish.yield(message("a"))
        publish.yield(message("b"))

        let delivered = await eventually { recorder.automatic == ["a", "b"] }
        XCTAssertTrue(delivered, "got \(recorder.automatic)")
    }

    func test_manual_handsEveryMessageToTheHandler_andPresentsNothing() async {
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(
            .manual { message in recorder.manual.append(message.id) },
            messages: messages,
            presentAutomatically: { message in recorder.automatic.append(message.id) }
        )
        defer { delivery.stop() }

        publish.yield(message("a"))
        publish.yield(message("b"))

        let delivered = await eventually { recorder.manual == ["a", "b"] }
        XCTAssertTrue(delivered, "got \(recorder.manual)")
        XCTAssertEqual(recorder.automatic, [], "the SDK must not present in manual mode")
    }

    func test_messagesArriveOneAtATime() async {
        // The next message waits until the handler for the current one
        // returns, so two presentations never overlap.
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(
            .manual { message in
                recorder.concurrent += 1
                recorder.maxConcurrent = max(recorder.maxConcurrent, recorder.concurrent)
                try? await Task.sleep(nanoseconds: 30_000_000)
                recorder.manual.append(message.id)
                recorder.concurrent -= 1
            },
            messages: messages,
            presentAutomatically: { _ in }
        )
        defer { delivery.stop() }

        publish.yield(message("a"))
        publish.yield(message("b"))
        publish.yield(message("c"))

        let delivered = await eventually { recorder.manual == ["a", "b", "c"] }
        XCTAssertTrue(delivered, "got \(recorder.manual)")
        XCTAssertEqual(recorder.maxConcurrent, 1)
    }

    func test_start_isIdempotent() async {
        let recorder = Recorder()
        let (messages, publish) = AsyncStream<InAppMessages.Message>.makeStream()
        let (otherMessages, _) = AsyncStream<InAppMessages.Message>.makeStream()
        let delivery = InAppMessageDelivery()
        delivery.start(.automatic, messages: messages, presentAutomatically: { message in
            recorder.automatic.append(message.id)
        })
        // A second start must not replace the first subscription.
        delivery.start(.manual { message in recorder.manual.append(message.id) },
                       messages: otherMessages,
                       presentAutomatically: { _ in })
        defer { delivery.stop() }

        publish.yield(message("a"))

        let delivered = await eventually { recorder.automatic == ["a"] }
        XCTAssertTrue(delivered)
        XCTAssertEqual(recorder.manual, [])
    }

    func test_manualHandler_trailingClosureSyntax() {
        // Pins the call-site shape the docs use:
        // `Galva.configure(apiKey: "…", inAppMessages: .manual { message in … })`
        let presentation: InAppMessages.Presentation = .manual { message in
            _ = message.id
        }
        guard case .manual = presentation else { return XCTFail("expected .manual") }
    }
}
