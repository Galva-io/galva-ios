//
//  SDKCoreIntegrationTests.swift
//  GalvaTests
//
//  `configure(…, integrations:)`: each integration installs exactly once,
//  after configure, and logs through a context logger that follows the SDK's
//  current logger and level.
//

import Foundation
@_spi(GalvaIntegration) @testable import Galva
import XCTest

/// Records integration installs. Lock-protected: installs run on detached
/// tasks.
private final class InstallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var installs: [(name: String, context: Galva.IntegrationContext)] = []

    func integration(named name: String) -> Galva.Integration {
        Galva.Integration(name: name, version: "1.0.0") { context in
            self.record(name, context)
        }
    }

    private func record(_ name: String, _ context: Galva.IntegrationContext) {
        lock.lock()
        installs.append((name, context))
        lock.unlock()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return installs.map { $0.name }
    }

    var firstContext: Galva.IntegrationContext? {
        lock.lock()
        defer { lock.unlock() }
        return installs.first?.context
    }

    /// Polls until `count` installs landed or ~2s passed.
    func waitForInstalls(_ count: Int) async {
        for _ in 0..<200 where names.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

@GalvaActor
final class SDKCoreIntegrationTests: XCTestCase {

    func test_configure_installsEachIntegrationOnce() async {
        let recorder = InstallRecorder()
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.configure(integrations: [
            recorder.integration(named: "first"),
            recorder.integration(named: "second"),
        ])
        await recorder.waitForInstalls(2)

        XCTAssertEqual(recorder.names.sorted(), ["first", "second"])
    }

    func test_secondConfigure_doesNotInstallItsIntegrations() async {
        let recorder = InstallRecorder()
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.configure(integrations: [recorder.integration(named: "first")])
        await recorder.waitForInstalls(1)
        await harness.configure(integrations: [recorder.integration(named: "late")])
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.names, ["first"])
    }

    func test_configureWithoutIntegrations_installsNothing() async {
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.configure()

        XCTAssertTrue(harness.core.configured)
    }

    func test_contextLogger_followsLoggerAndLevelSetAfterInstall() async throws {
        let recorder = InstallRecorder()
        let harness = SDKHarness.make()
        defer { harness.cleanup() }

        await harness.configure(integrations: [recorder.integration(named: "first")])
        await recorder.waitForInstalls(1)
        let context = try XCTUnwrap(recorder.firstContext)

        // Installed after the integration captured its context — the
        // integration's logger must pick it up, with its level.
        let sink = RecordingLogger()
        harness.core.installLogger(sink, minLevel: .warning)

        context.logger.info(.integration, "filtered out")
        context.logger.warning(.integration, "kept")

        XCTAssertEqual(sink.entries.map(\.message), ["kept"])
    }
}
