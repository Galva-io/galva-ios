//
//  Logger.swift
//  Galva
//
//  Galva's logging surface — designed for "great DX": developers and QA
//  can see exactly what the SDK is doing in real time, and apps can
//  forward Galva's logs into their own pipeline.
//
//  ┌─────────────────────────────────────────────────────────────────────┐
//  │  Concepts                                                           │
//  │                                                                     │
//  │  GalvaLogger      — public protocol any logger conforms to.         │
//  │  Galva.LogEntry   — the value passed to log(_:); future-proof.      │
//  │  OSLogLogger      — default, writes to `os.Logger(subsystem:"co.    │
//  │                     galva.sdk", category:"queue|uploader|…")` so    │
//  │                     QA can filter in Console.app.                   │
//  │  LevelFilterLogger — wraps a logger and drops entries below `min`.   │
//  │                                                                     │
//  │  Pipeline assembled in SDKCore:                                     │
//  │     entries → LevelFilter(min: configured) → user-supplied | OSLog  │
//  └─────────────────────────────────────────────────────────────────────┘
//
//  Custom logger example (forwards to Sentry breadcrumbs):
//
//      struct SentryGalvaLogger: GalvaLogger {
//          func log(_ entry: Galva.LogEntry) {
//              SentrySDK.addBreadcrumb(...)
//          }
//      }
//      Galva.setLogger(SentryGalvaLogger())
//

import Foundation
import os.log

// MARK: - GalvaLogger protocol

/// A sink for Galva log entries. Implement this protocol to forward SDK
/// logs into your own pipeline (Sentry, Datadog, a custom file logger),
/// then install it via `Galva.setLogger(_:)`.
///
/// Conformers receive every entry — filtering by level happens upstream
/// in the `LevelFilterLogger` the SDK installs by default.
///
/// **Performance note** — implement `isEnabled(_:)` if your logger
/// short-circuits at a level threshold. The SDK's call sites check
/// `isEnabled` *before* evaluating their message autoclosures, so a
/// filtered-out `logger.debug(.queue, "expensive \(work)")` costs
/// nothing beyond a method call and a comparison.
public protocol GalvaLogger: Sendable {
    func log(_ entry: Galva.LogEntry)

    /// Cheap pre-check. The SDK's convenience methods call this before
    /// building the `LogEntry` so the message autoclosure doesn't run
    /// for an entry that would be dropped. Default returns `true`.
    func isEnabled(_ level: Galva.LogLevel) -> Bool
}

public extension GalvaLogger {
    func isEnabled(_ level: Galva.LogLevel) -> Bool { true }
}

// MARK: - LogEntry

public extension Galva {

    /// A single log entry handed to any `GalvaLogger`. New fields will be
    /// added over time — conform to `GalvaLogger` with a single method to
    /// avoid breaking-change pain.
    struct LogEntry: Sendable {
        public let level: LogLevel
        public let category: LogCategory
        public let message: String
        public let metadata: [String: String]
        public let error: (any Error)?
        public let file: StaticString
        public let line: UInt
        public let timestamp: Date

        public init(
            level: LogLevel,
            category: LogCategory,
            message: String,
            metadata: [String: String] = [:],
            error: (any Error)? = nil,
            file: StaticString = #file,
            line: UInt = #line,
            timestamp: Date = Date()
        ) {
            self.level = level
            self.category = category
            self.message = message
            self.metadata = metadata
            self.error = error
            self.file = file
            self.line = line
            self.timestamp = timestamp
        }
    }
}

// MARK: - Convenience methods

/// Ergonomic wrappers used at call sites — keeps the body of an SDK
/// method readable without sacrificing structured-log fidelity.
///
///     logger.debug(.queue, "drained \(batch.count) messages")
///     logger.warning(.uploader, "retryable failure", metadata: ["status": "503"], error: err)
///
public extension GalvaLogger {
    func debug(
        _ category: Galva.LogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        error: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard isEnabled(.debug) else { return }
        log(Galva.LogEntry(
            level: .debug, category: category, message: message(),
            metadata: metadata, error: error, file: file, line: line
        ))
    }

    func info(
        _ category: Galva.LogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        error: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard isEnabled(.info) else { return }
        log(Galva.LogEntry(
            level: .info, category: category, message: message(),
            metadata: metadata, error: error, file: file, line: line
        ))
    }

    func notice(
        _ category: Galva.LogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        error: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard isEnabled(.notice) else { return }
        log(Galva.LogEntry(
            level: .notice, category: category, message: message(),
            metadata: metadata, error: error, file: file, line: line
        ))
    }

    func warning(
        _ category: Galva.LogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        error: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard isEnabled(.warning) else { return }
        log(Galva.LogEntry(
            level: .warning, category: category, message: message(),
            metadata: metadata, error: error, file: file, line: line
        ))
    }

    func error(
        _ category: Galva.LogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        error: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard isEnabled(.error) else { return }
        log(Galva.LogEntry(
            level: .error, category: category, message: message(),
            metadata: metadata, error: error, file: file, line: line
        ))
    }

    func fault(
        _ category: Galva.LogCategory,
        _ message: @autoclosure () -> String,
        metadata: [String: String] = [:],
        error: (any Error)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard isEnabled(.fault) else { return }
        log(Galva.LogEntry(
            level: .fault, category: category, message: message(),
            metadata: metadata, error: error, file: file, line: line
        ))
    }
}

// MARK: - OSLogLogger (default)

/// Default logger implementation. Writes to one `os.Logger` per
/// `Galva.LogCategory`, all under the same subsystem so QA can filter
/// the whole SDK out of system noise in Console.app:
///
///     subsystem:co.galva.sdk
///
/// Each category is its own OSLog stream:
///
///     subsystem:co.galva.sdk category:queue
///
/// `os.Logger` is the system-recommended logger as of iOS 14 — it's
/// structured, automatically timestamped, persisted, and shows up in
/// Xcode's debug console.
struct OSLogLogger: GalvaLogger {

    /// Subsystem applied to every `os.Logger` instance.
    static let defaultSubsystem = "co.galva.sdk"

    private let subsystem: String
    /// One `os.Logger` per category, cached at construction.
    private let loggersByCategory: [Galva.LogCategory: os.Logger]

    init(subsystem: String = OSLogLogger.defaultSubsystem) {
        self.subsystem = subsystem
        var cache: [Galva.LogCategory: os.Logger] = [:]
        for category in Galva.LogCategory.allCases {
            cache[category] = os.Logger(subsystem: subsystem, category: category.rawValue)
        }
        self.loggersByCategory = cache
    }

    func log(_ entry: Galva.LogEntry) {
        guard entry.level != .off, let logger = loggersByCategory[entry.category] else {
            return
        }
        let formatted = Self.format(entry)
        switch entry.level {
        case .debug:   logger.debug("\(formatted, privacy: .public)")
        case .info:    logger.info("\(formatted, privacy: .public)")
        case .notice:  logger.notice("\(formatted, privacy: .public)")
        case .warning: logger.warning("\(formatted, privacy: .public)")
        case .error:   logger.error("\(formatted, privacy: .public)")
        case .fault:   logger.fault("\(formatted, privacy: .public)")
        case .off:     break
        }
    }

    /// Build a single line: `"message k1=v1 k2=v2 error=..."`. Metadata
    /// keys are sorted for stable readability.
    static func format(_ entry: Galva.LogEntry) -> String {
        var out = entry.message
        if !entry.metadata.isEmpty {
            let pairs = entry.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            out += " " + pairs
        }
        if let error = entry.error {
            out += " error=\(String(describing: error))"
        }
        return out
    }
}

// MARK: - LevelFilterLogger

/// Wraps another logger and drops entries below `minLevel`. SDKCore
/// installs one of these around whatever logger is configured (user-
/// supplied or default OSLog) so the `Galva.configure(logLevel:)`
/// setting actually controls output.
struct LevelFilterLogger: GalvaLogger {
    let minLevel: Galva.LogLevel
    let wrapped: any GalvaLogger

    func log(_ entry: Galva.LogEntry) {
        guard isEnabled(entry.level) else { return }
        wrapped.log(entry)
    }

    /// Composes with the wrapped logger so a Sentry/Datadog logger that
    /// applies its own filter can still report the effective cutoff.
    func isEnabled(_ level: Galva.LogLevel) -> Bool {
        guard minLevel != .off, level >= minLevel else { return false }
        return wrapped.isEnabled(level)
    }
}

// MARK: - Disabled logger

/// A no-op logger. Useful as a default before configure() runs and in
/// tests that want to suppress all output.
struct NoOpLogger: GalvaLogger {
    func log(_ entry: Galva.LogEntry) {}
    func isEnabled(_ level: Galva.LogLevel) -> Bool { false }
}
