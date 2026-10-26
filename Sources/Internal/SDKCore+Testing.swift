//
//  SDKCore+Testing.swift
//  Galva
//
//  Test-only surface for SDKCore. Lives in `Sources/Internal/` (not in
//  `Tests/`) because the helpers reach internal storage on SDKCore; an
//  extension in another target wouldn't have visibility. Kept in its own
//  file so the production code in SDKCore.swift stays focused on the
//  app-facing pipeline.
//
//  None of this is part of the SDK's public API — every member is at most
//  module-internal, and the test target reaches them via
//  `@testable import Galva`.
//

import Foundation

/// Points `SDKCore.shared` — and so every public entry point — at a test's
/// own core: `SDKCoreTestBinding.$core.withValue(harness.core) { … }`.
/// Calls made inside, and tasks they start, reach that core instead of the
/// production singleton.
enum SDKCoreTestBinding {
    @TaskLocal static var core: SDKCore?
}

@GalvaActor
extension SDKCore {

    /// Read-only view of whether `configure(...)` (or `configureForTesting`)
    /// has run. Used by SDKCoreConfigurationTests to assert state transitions
    /// without exposing internal storage.
    var isConfigured: Bool { configured }

    /// Wire up pre-built dependencies, skipping the production setup that
    /// builds a real `Uploader` and a SQLite-backed `MessageQueue`. Then
    /// runs the same startup as `configure(apiKey:autoTrack:logLevel:)` —
    /// `beginConfiguring()` and `finishConfiguring(queue:integrations:)`:
    ///   • a repeat call is ignored; `submit`ted calls wait for it, then run
    ///     in order
    ///   • seeds an initial identify with device traits, then replays a
    ///     deferred deep link
    ///   • starts the queue runloop
    ///
    /// `midConfigure` runs where production suspends for the MainActor
    /// snapshot — after the identity is set, before the queue and context
    /// exist — so a test can hold configure there.
    ///
    /// Tests construct their own SDKCore instance (not `.shared`) so state
    /// doesn't leak between tests, and supply a queue backed by a recording
    /// consumer to assert on emitted messages.
    func configureForTesting(
        identity: IdentityStore,
        queue: MessageQueue,
        contextProvider: ContextProvider,
        logger: any GalvaLogger = OSLogLogger(),
        minLogLevel: Galva.LogLevel = .debug,
        integrations: [Galva.Integration] = [],
        midConfigure: (@Sendable () async -> Void)? = nil
    ) async {
        guard beginConfiguring() else {
            self.logger.warning(.configuration, "configure called more than once — ignoring")
            return
        }
        // Mirror production: store the sink + level and rebuild the filter
        // through the same code path. Default `minLogLevel` is `.debug` so
        // tests see every breadcrumb out of the box. Later calls to
        // `installLogger(_:)` preserve the same filter level.
        installLogger(logger, minLevel: minLogLevel)
        self.identity = identity
        if let midConfigure { await midConfigure() }
        self.queue = queue
        self.contextProvider = contextProvider
        setCachedEndUserId(identity.endUserId)
        setCachedAppAccountToken(identity.purchaseAttributionToken)
        self.logger.info(.configuration, "SDK configured (testing)", metadata: [
            "anonymousId": identity.anonymousId,
        ])
        await finishConfiguring(queue: queue, integrations: integrations)
    }
}
