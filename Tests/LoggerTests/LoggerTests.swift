//
//  LoggerTests.swift
//  GalvaTests
//
//  Covers the public logging surface:
//
//    • `Galva.LogLevel` ordering (used by the filter)
//    • Convenience methods route to the right level/category
//    • `LevelFilterLogger` drops entries below `minLevel` and is silent
//      when `minLevel == .off`
//    • `OSLogLogger.format(...)` produces a stable, grep-friendly line
//    • Custom logger installed via `SDKCore.installLogger(_:)` receives
//      every SDK breadcrumb the level filter lets through
//
//  We avoid asserting against the real OSLog backend (it writes to a
//  system stream we can't read deterministically). Instead, a small
//  `RecordingLogger` actor captures entries for inspection.
//

import Foundation
@testable import Galva
import XCTest

// MARK: - RecordingLogger

/// In-memory logger used to assert what entries the SDK emits.
/// Conforms to `GalvaLogger` (a public protocol) so it's exactly the
/// shape custom integrators would write.
///
/// Backed by an `NSLock` instead of an actor so `log(_:)` is fully
/// synchronous — tests can read `entries` immediately after the call
/// without sleeping or polling for task flushes.
final class RecordingLogger: GalvaLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [Galva.LogEntry] = []

    var entries: [Galva.LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }

    func log(_ entry: Galva.LogEntry) {
        lock.lock(); defer { lock.unlock() }
        _entries.append(entry)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        _entries.removeAll()
    }
}

// MARK: - LogLevel ordering

final class LogLevelTests: XCTestCase {

    func test_levels_areOrderedBySeverity() {
        XCTAssertLessThan(Galva.LogLevel.debug, .info)
        XCTAssertLessThan(Galva.LogLevel.info, .notice)
        XCTAssertLessThan(Galva.LogLevel.notice, .warning)
        XCTAssertLessThan(Galva.LogLevel.warning, .error)
        XCTAssertLessThan(Galva.LogLevel.error, .fault)
        XCTAssertLessThan(Galva.LogLevel.fault, .off)
    }
}

// MARK: - Convenience routing

final class LoggerConvenienceTests: XCTestCase {

    func test_debug_emitsAtDebugLevel() {
        let logger = RecordingLogger()
        logger.debug(.queue, "drained")
        XCTAssertEqual(logger.entries.count, 1)
        XCTAssertEqual(logger.entries.first?.level, .debug)
        XCTAssertEqual(logger.entries.first?.category, .queue)
        XCTAssertEqual(logger.entries.first?.message, "drained")
    }

    func test_info_emitsAtInfoLevel() {
        let logger = RecordingLogger()
        logger.info(.configuration, "ready")
        XCTAssertEqual(logger.entries.first?.level, .info)
        XCTAssertEqual(logger.entries.first?.category, .configuration)
    }

    func test_warning_carriesError() {
        let logger = RecordingLogger()
        let err = TestError("transient")
        logger.warning(.uploader, "retryable", metadata: ["status": "503"], error: err)
        XCTAssertEqual(logger.entries.first?.level, .warning)
        XCTAssertEqual(logger.entries.first?.metadata["status"], "503")
        XCTAssertNotNil(logger.entries.first?.error)
    }

    func test_error_andFault_emitAtRightLevels() {
        let logger = RecordingLogger()
        logger.error(.storage, "fetch failed")
        logger.fault(.queue, "invariant broken")
        XCTAssertEqual(logger.entries.map(\.level), [.error, .fault])
    }
}

// MARK: - LevelFilterLogger

final class LevelFilterLoggerTests: XCTestCase {

    func test_dropsEntriesBelowMin() {
        let inner = RecordingLogger()
        let filter = LevelFilterLogger(minLevel: .warning, wrapped: inner)

        filter.debug(.queue, "debug")
        filter.info(.queue, "info")
        filter.notice(.queue, "notice")
        filter.warning(.queue, "warn")
        filter.error(.queue, "err")
        filter.fault(.queue, "fault")

        XCTAssertEqual(inner.entries.map(\.level), [.warning, .error, .fault])
    }

    func test_off_suppressesEverything() {
        let inner = RecordingLogger()
        let filter = LevelFilterLogger(minLevel: .off, wrapped: inner)

        for level: Galva.LogLevel in [.debug, .info, .notice, .warning, .error, .fault] {
            filter.log(Galva.LogEntry(level: level, category: .queue, message: "x"))
        }

        XCTAssertTrue(inner.entries.isEmpty, "minLevel = .off must suppress all entries")
    }

    func test_debugMin_passesEverything() {
        let inner = RecordingLogger()
        let filter = LevelFilterLogger(minLevel: .debug, wrapped: inner)

        for level: Galva.LogLevel in [.debug, .info, .notice, .warning, .error, .fault] {
            filter.log(Galva.LogEntry(level: level, category: .queue, message: "x"))
        }
        XCTAssertEqual(inner.entries.count, 6, "minLevel = .debug must pass everything except .off")
    }
}

// MARK: - OSLogLogger format

final class OSLogLoggerFormatTests: XCTestCase {

    func test_format_messageOnly() {
        let entry = Galva.LogEntry(
            level: .info, category: .queue, message: "drained 5 messages"
        )
        XCTAssertEqual(OSLogLogger.format(entry), "drained 5 messages")
    }

    func test_format_appendsSortedMetadata() {
        let entry = Galva.LogEntry(
            level: .info,
            category: .queue,
            message: "drained",
            metadata: ["batchSize": "5", "attempt": "1"]
        )
        // Keys sorted alphabetically for grep-friendly output.
        XCTAssertEqual(
            OSLogLogger.format(entry),
            "drained attempt=1 batchSize=5"
        )
    }

    func test_format_appendsError() {
        let entry = Galva.LogEntry(
            level: .error, category: .uploader, message: "failed",
            error: TestError("transport")
        )
        XCTAssertTrue(OSLogLogger.format(entry).contains("error="))
        XCTAssertTrue(OSLogLogger.format(entry).contains("transport"))
    }
}

// MARK: - End-to-end: SDKCore breadcrumbs reach a custom logger

@GalvaActor
final class SDKCoreLoggingTests: XCTestCase {

    func test_configure_emitsBreadcrumb() async {
        let logger = RecordingLogger()
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.core.configureForTesting(
            identity: harness.identity,
            queue: MessageQueueAccess.queue(for: harness.consumer, storage: harness.storage),
            contextProvider: ContextProvider(),
            logger: logger
        )

        XCTAssertTrue(
            logger.entries.contains { $0.category == .configuration && $0.level == .info },
            "configure should emit a .configuration info breadcrumb. Got: \(logger.entries.map { "\($0.category).\($0.level)" })"
        )
    }

    func test_track_emitsDebugBreadcrumb() async {
        let logger = RecordingLogger()
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.core.configureForTesting(
            identity: harness.identity,
            queue: MessageQueueAccess.queue(for: harness.consumer, storage: harness.storage),
            contextProvider: ContextProvider(),
            logger: logger
        )
        logger.reset()
        await harness.core.track(event: "TestEvent", properties: nil)

        guard let trackEntry = logger.entries.first(where: {
            $0.category == .identity && $0.message == "track"
        }) else {
            return XCTFail("Expected a track debug breadcrumb. Got: \(logger.entries.map(\.message))")
        }
        XCTAssertEqual(trackEntry.level, .debug)
        XCTAssertEqual(trackEntry.metadata["event"], "TestEvent")
    }

    func test_installLogger_replacesSink() async {
        let firstLogger = RecordingLogger()
        let secondLogger = RecordingLogger()
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        // Use the testing hook (no network) but with a level filter
        // wrapping firstLogger to exercise the same path production uses.
        let filtered = LevelFilterLogger(minLevel: .debug, wrapped: firstLogger)
        await harness.core.configureForTesting(
            identity: harness.identity,
            queue: MessageQueueAccess.queue(for: harness.consumer, storage: harness.storage),
            contextProvider: ContextProvider(),
            logger: filtered
        )
        // Override mid-flight.
        harness.core.installLogger(secondLogger)
        firstLogger.reset()
        await harness.core.track(event: "AfterSwap", properties: nil)

        XCTAssertTrue(
            secondLogger.entries.contains { $0.metadata["event"] == "AfterSwap" },
            "Second logger must receive entries after installLogger"
        )
        XCTAssertFalse(
            firstLogger.entries.contains { $0.metadata["event"] == "AfterSwap" },
            "First logger must not receive entries after it was replaced"
        )
    }
}
