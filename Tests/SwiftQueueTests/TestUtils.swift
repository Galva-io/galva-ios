// The MIT License (MIT)
//
// Copyright (c) 2022 Lucas Nelaupe
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Dispatch
import Foundation
@testable import Galva
import XCTest


class TestJob: Job {
    private let onRunCallback: () async throws -> Void
    private var withRetry: RetryConstraint

    private var onRunCount = 0
    private var onRetryCount = 0
    private var onCompletedCount = 0
    private var onCanceledCount = 0

    private let onRemoveSemaphore = DispatchSemaphore(value: 0)

    private var runSemaphoreValue = 0

    private var lastError: Error?

    init(retry: RetryConstraint = .retry(delay: 0), onRunCallback: @escaping () async throws -> Void = {}) {
        self.onRunCallback = onRunCallback
        withRetry = retry
    }

    func onRun() async throws {
        onRunCount += 1
        try await onRunCallback()
    }

    func onRetry(error: Error) -> RetryConstraint {
        lastError = error
        onRetryCount += 1
        return withRetry
    }

    func onRemove(result: JobCompletion) {
        switch result {
        case .success:
            lastError = nil
            onCompletedCount += 1
            onRemoveSemaphore.signal()

        case let .fail(error):
            lastError = error
            onCanceledCount += 1
            onRemoveSemaphore.signal()
        }
    }

    // Wait

    func awaitForRemoval() {
        onRemoveSemaphore.wait()
    }

    // Assertion

    public func assertRunCount(expected: Int, file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertEqual(expected, onRunCount)
    }

    public func assertCompletedCount(expected: Int, file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertEqual(expected, onCompletedCount)
    }

    public func assertRetriedCount(expected: Int, file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertEqual(expected, onRetryCount)
    }

    public func assertCanceledCount(expected: Int, file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertEqual(expected, onCanceledCount)
    }

    public func assertError(file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertTrue(lastError is JobError)
    }

    public func assertError(queueError: SwiftQueueError, file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertTrue(lastError is SwiftQueueError)
        guard let base: SwiftQueueError = lastError as? SwiftQueueError else { return }
        switch (base, queueError) {
        case let (.onRetryCancel(lErr), .onRetryCancel(rErr)):
            XCTAssertEqual(lErr as? JobError, rErr as? JobError)
        case (.duplicate, .duplicate): return
        case (.deadline, .deadline): return
        case (.canceled, .canceled): return
        case (.timeout, .timeout): return
        default: XCTFail("Type mismatch")
        }
    }

    public func assertNoError(file _: StaticString = #file, line _: UInt = #line) {
        XCTAssertNil(lastError)
    }

    public func assertNoRun(file: StaticString = #file, line: UInt = #line) {
        assertRunCount(expected: 0)
        assertCompletedCount(expected: 0)
        assertRetriedCount(expected: 0)
        assertCanceledCount(expected: 0)
        assertNoError(file: file, line: line)
    }

    // Job has run once without error and completed
    public func assertSingleCompletion(file: StaticString = #file, line: UInt = #line) {
        assertRunCount(expected: 1)
        assertCompletedCount(expected: 1)
        assertRetriedCount(expected: 0)
        assertCanceledCount(expected: 0)
        assertNoError(file: file, line: line)
    }

    public func assertRemovedBeforeRun(reason: SwiftQueueError, file _: StaticString = #file, line _: UInt = #line) {
        assertRunCount(expected: 0)
        assertCompletedCount(expected: 0)
        assertRetriedCount(expected: 0)
        assertCanceledCount(expected: 1)
        assertError(queueError: reason)
    }
}

class TestJobFail: TestJob {
    required init(retry: RetryConstraint = .retry(delay: 0), error: Error = JobError()) {
        super.init(retry: retry) { throw error }
    }
}

class TestCreator: JobCreator {
    private let job: [String: Job]

    public init(_ job: [String: Job]) {
        self.job = job
    }

    func create(type: String, params _: [String: Any]?) -> Job {
        return job[type]!
    }
}

class PersisterTracker: UserDefaultsPersister {
    var restoreQueueName = ""

    var putQueueName: [String] = .init()
    var putJobUUID: [String] = .init()
    var putData: [String] = .init()

    var removeQueueName: [String] = .init()
    var removeJobUUID: [String] = .init()

    override func restore(queueName: String) -> [String] {
        restoreQueueName = queueName
        return super.restore(queueName: queueName)
    }

    override func put(queueName: String, taskId: String, data: String) {
        putQueueName.append(queueName)
        putJobUUID.append(taskId)
        putData.append(data)
        super.put(queueName: queueName, taskId: taskId, data: data)
    }

    override func remove(queueName: String, taskId: String) {
        removeQueueName.append(queueName)
        removeJobUUID.append(taskId)
        super.remove(queueName: queueName, taskId: taskId)
    }
}

class JobListenerTest: JobListener {
    var onJobScheduled: [JobInfo] = .init()
    var onBeforeRun: [JobInfo] = .init()
    var onAfterRun: [(JobInfo, JobCompletion)] = .init()
    var onTerminated: [(JobInfo, JobCompletion)] = .init()

    func onJobScheduled(job: JobInfo) {
        onJobScheduled.append(job)
    }

    func onBeforeRun(job: JobInfo) {
        onBeforeRun.append(job)
    }

    func onAfterRun(job: JobInfo, result: JobCompletion) {
        onAfterRun.append((job, result))
    }

    func onTerminated(job: JobInfo, result: JobCompletion) {
        onTerminated.append((job, result))
    }
}

class JobError: Error, @unchecked Sendable {
    let id = UUID().uuidString
}

extension JobError: Equatable {
    public static func == (lhs: JobError, rhs: JobError) -> Bool {
        return lhs.id == rhs.id
    }
}

extension SqOperation {
    func toJSONStringSafe() -> String {
        (try? DecodableSerializer(maker: DefaultConstraintMaker()).serialize(info: info)) ?? "{}"
    }
}

class NoPersister: JobPersister {
    public nonisolated(unsafe) static let shared = NoPersister()

    private init() {}

    func restore() -> [String] { return [] }

    func restore(queueName _: String) -> [String] { return [] }

    func put(queueName _: String, taskId _: String, data _: String) {}

    func remove(queueName _: String, taskId _: String) {}

    func clearAll() {}
}

class MemorySerializer: JobInfoSerializer {
    private var data: [String: JobInfo] = [:]

    func serialize(info: JobInfo) throws -> String {
        let constraint: UniqueUUIDConstraint? = getConstraint(info)
        let uuid = constraint?.uuid ?? ""
        assertNotEmptyString(uuid)
        data[uuid] = info
        return uuid
    }

    func deserialize(json: String) throws -> JobInfo {
        return data[json] ?? JobInfo(type: json)
    }
}

extension JobBuilder {
    func build(job: Job, logger: SwiftQueueLogger = NoLogger.shared, listener: JobListener? = nil) -> SqOperation {
        let info = build()
        let constraints = info.constraints
        return SqOperation(job, info, logger, listener, DispatchQueue.global(qos: .userInitiated), constraints)
    }
}

extension SwiftQueueManagerBuilder {
    /// Convenience for tests: uses userInitiated QoS to avoid priority inversions with XCTest semaphores
    static func testBuilder(creator: JobCreator) -> SwiftQueueManagerBuilder {
        return SwiftQueueManagerBuilder(creator: creator)
            .set(persister: NoPersister.shared)
            .set(dispatchQueue: DispatchQueue.global(qos: .userInitiated))
    }
}
