//
//  SDKCoreTestSupport.swift
//  GalvaTests
//
//  Shared harness for SDKCore integration tests.
//
//  Each test builds an `SDKHarness` instance. The harness wires:
//    • a fresh `SDKCore` (not the production singleton, so tests don't
//      contaminate each other)
//    • an in-memory `MessageQueue` backed by a `RecordingConsumer` so
//      tests can inspect every emitted Message
//    • an isolated `UserDefaults` suite for `IdentityStore`, deleted on
//      teardown so identity state doesn't leak across tests
//    • a `SilentLogger` to keep test console output clean
//
//  Usage in a test:
//      let harness = await SDKHarness.make()
//      defer { harness.cleanup() }
//      await harness.configure()
//      await harness.core.track(event: "evt", properties: nil)
//      let events = await harness.consumer.consumedEvents
//      XCTAssertEqual(events, ["evt"])
//

import Foundation
@testable import Galva
import XCTest

/// Bundle of everything an SDKCore test needs: the SDK under test, the
/// recording consumer for assertions, and the resources to clean up.
struct SDKHarness: Sendable {
    let core: SDKCore
    let consumer: RecordingConsumer
    let storage: InMemoryMessageStorage
    let identity: IdentityStore
    let userDefaultsSuiteName: String

    /// Build a fully-wired but unconfigured harness. Call `configure()` to
    /// run the SDK's startup path (which also seeds an initial identify
    /// message — keep that in mind when asserting on consumed messages).
    @GalvaActor
    static func make() -> SDKHarness {
        let suiteName = "co.galva.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Failed to allocate UserDefaults suite for test")
        }
        let consumer = RecordingConsumer()
        let storage = InMemoryMessageStorage()
        let identity = IdentityStore(defaults: defaults)
        let core = SDKCore()

        return SDKHarness(
            core: core,
            consumer: consumer,
            storage: storage,
            identity: identity,
            userDefaultsSuiteName: suiteName
        )
    }

    /// Convenience — make + configure. Most tests want both.
    @GalvaActor
    static func makeConfigured() async -> SDKHarness {
        let harness = make()
        await harness.configure()
        return harness
    }

    /// `midConfigure` runs where production configure suspends (the MainActor
    /// snapshot), before the queue exists — await a `TestGate` in it to hold
    /// configure there.
    @GalvaActor
    func configure(
        logger: any GalvaLogger = SilentLogger(),
        integrations: [Galva.Integration] = [],
        midConfigure: (@Sendable () async -> Void)? = nil
    ) async {
        let queue = MessageQueueAccess.queue(for: consumer, storage: storage)
        await core.configureForTesting(
            identity: identity,
            queue: queue,
            contextProvider: ContextProvider(),
            logger: logger,
            integrations: integrations,
            midConfigure: midConfigure
        )
    }

    /// An in-app message manager on this harness's identity and stream, for
    /// tests that assign it to `core.inAppMessageManager`. Network goes to
    /// `URLProtocolStub`; bundles to a temp directory.
    @GalvaActor
    func makeInAppMessageManager() -> InAppMessageManager {
        makeInAppMessaging().manager
    }

    /// Wire in-app messaging into `core` (manager + bundle cache), as
    /// configure does, without the lifecycle observer. Returns the manager.
    @GalvaActor
    func installInAppMessaging() -> InAppMessageManager {
        let (manager, bundleCache) = makeInAppMessaging()
        core.inAppMessageManager = manager
        core.bundleCache = bundleCache
        return manager
    }

    @GalvaActor
    private func makeInAppMessaging() -> (manager: InAppMessageManager, bundleCache: WebViewBundleCache) {
        let client = APIClient(
            baseURL: URL(string: "https://api.galva.test")!,
            apiKey: "pk_test",
            session: URLProtocolStub.makeSession(),
            logger: SilentLogger()
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("galva-harness-\(UUID().uuidString)", isDirectory: true)
        guard let bundleCache = try? WebViewBundleCache(
            directoryURL: directory,
            client: client,
            cdnBaseURL: URL(string: "https://webview.galva.test")!,
            logger: SilentLogger()
        ) else {
            preconditionFailure("Failed to create a bundle cache for test")
        }
        let manager = InAppMessageManager(
            client: client,
            identity: identity,
            stream: core.inAppMessageStream,
            bundleCache: bundleCache,
            initialization: InitializationManager(client: client, cache: nil, logger: SilentLogger()),
            logger: SilentLogger()
        )
        return (manager, bundleCache)
    }

    /// The isolated UserDefaults suite — for state the SDK keeps outside
    /// `IdentityStore`, such as the opt-out flag.
    var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: userDefaultsSuiteName) else {
            preconditionFailure("Failed to open UserDefaults suite for test")
        }
        return defaults
    }

    /// Drain the isolated UserDefaults suite. Call from `tearDown` so
    /// identity rows don't pile up on disk across test runs.
    func cleanup() {
        UserDefaults(suiteName: userDefaultsSuiteName)?
            .removePersistentDomain(forName: userDefaultsSuiteName)
    }
}

/// One-shot signal: `wait()` suspends until `open()` is called. Two of them
/// (reached / release) hold `SDKHarness.configure(midConfigure:)` mid-flight
/// while a test makes calls.
actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Tiny indirection so the harness can rebuild the MessageQueue inside
/// `configure()` (the queue stored on the harness was used at construction
/// only — we want the same queue at configure time but with the same
/// consumer/storage so assertions still hold).
///
/// In practice we reuse the same queue instance — but routing through a
/// helper makes it easy to swap in a different queue later (e.g. one with
/// a batching window) without changing every test.
enum MessageQueueAccess {
    @GalvaActor
    static func queue(
        for consumer: RecordingConsumer,
        storage: InMemoryMessageStorage,
        options: MessageQueue.QueueOptions? = nil
    ) -> MessageQueue {
        MessageQueue(consumer: consumer, storage: storage, options: options)
    }
}

// MARK: - Message-introspection helpers

extension Message {
    /// Convenience for tests — narrow the body to identify traits or nil.
    var identifyTraits: [String: AnyJSONValue]? {
        if case .identify(let traits) = body { return traits }
        return nil
    }

    /// Convenience for tests — extract the endpoint from a
    /// create/delete-communication-endpoint message.
    var communicationEndpoint: CommunicationEndpoint? {
        switch body {
        case .createCommunicationEndpoint(let ep),
             .deleteCommunicationEndpoint(let ep):
            return ep
        default:
            return nil
        }
    }

    /// Convenience for tests — extract `(channelType, disabled, categories)`
    /// from a set-communication-preference message.
    var preferenceTuple: (CommunicationEndpoint.ChannelType, Bool?, [String: Bool]?)? {
        if case .setCommunicationPreference(let c, let d, let cats) = body {
            return (c, d, cats)
        }
        return nil
    }
}
