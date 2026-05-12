//
//  UploadConsumerTests.swift
//  GalvaTests
//
//  UploadConsumer translates UploadOutcome → MessageQueue contract:
//
//    .success    → return (queue deletes the batch)
//    .permanent  → return (queue deletes the batch; we log it and drop)
//    .retryable  → throw   (queue retains the batch and retries)
//
//  We test with a fake `MessageUploader` so there's no HTTP involved at
//  this level — Uploader's own HTTP behavior is covered separately.
//

import Foundation
@testable import Galva
import XCTest

final class UploadConsumerTests: XCTestCase {

    func test_success_returnsNormally() async throws {
        let uploader = FakeUploader(outcome: .success)
        let consumer = UploadConsumer(uploader: uploader, logger: SilentLogger())
        try await consumer.consume(messages: [sampleMessage()])
        // No throw == queue will delete the batch.
        await XCTAsyncAssertEqual(await uploader.callCount, 1)
    }

    func test_permanentFailure_returnsNormallyAndLogs() async throws {
        let uploader = FakeUploader(outcome: .permanent(TestError("bad-request")))
        let consumer = UploadConsumer(uploader: uploader, logger: SilentLogger())
        // Permanent ≡ "no point retrying". Consumer must NOT throw — the
        // queue deletes the batch and the SDK logs it.
        try await consumer.consume(messages: [sampleMessage()])
        await XCTAsyncAssertEqual(await uploader.callCount, 1)
    }

    func test_retryableFailure_throws() async {
        let uploader = FakeUploader(outcome: .retryable(TestError("server-blip")))
        let consumer = UploadConsumer(uploader: uploader, logger: SilentLogger())

        do {
            try await consumer.consume(messages: [sampleMessage()])
            XCTFail("Retryable outcome must throw so the queue retains the batch")
        } catch {
            // ok — expected
        }
        await XCTAsyncAssertEqual(await uploader.callCount, 1)
    }

    func test_emptyBatch_stillPassesThroughToUploader() async throws {
        // UploadConsumer doesn't short-circuit empty batches; the uploader
        // does. We just confirm the call is forwarded.
        let uploader = FakeUploader(outcome: .success)
        let consumer = UploadConsumer(uploader: uploader, logger: SilentLogger())
        try await consumer.consume(messages: [])
        await XCTAsyncAssertEqual(await uploader.callCount, 1)
    }

    func test_forwardsExactMessagesUnchanged() async throws {
        let uploader = FakeUploader(outcome: .success)
        let consumer = UploadConsumer(uploader: uploader, logger: SilentLogger())
        let batch = [
            sampleMessage(event: "a"),
            sampleMessage(event: "b"),
            sampleMessage(event: "c"),
        ]
        try await consumer.consume(messages: batch)
        let received = await uploader.lastBatch
        XCTAssertEqual(received?.map(\.event), ["a", "b", "c"])
    }
}

// MARK: - Fake uploader

actor FakeUploader: MessageUploader {
    private(set) var callCount = 0
    private(set) var lastBatch: [Message]?
    private let outcome: UploadOutcome

    init(outcome: UploadOutcome) {
        self.outcome = outcome
    }

    func upload(messages: [Message]) async -> UploadOutcome {
        callCount += 1
        lastBatch = messages
        return outcome
    }
}

// MARK: - Fixtures

private func sampleMessage(event: String = "evt") -> Message {
    Message(
        anonymousId: "anon",
        endUserId: nil,
        context: nil,
        body: .track(event: event, properties: nil, sourceType: nil, sourceId: nil)
    )
}
