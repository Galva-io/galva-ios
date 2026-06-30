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

@GalvaActor
extension SDKCore {

    /// Read-only view of whether `configure(...)` (or `configureForTesting`)
    /// has run. Used by SDKCoreConfigurationTests to assert state transitions
    /// without exposing internal storage.
    var isConfigured: Bool { configured }

    /// Wire up pre-built dependencies, skipping the production setup that
    /// builds a real `Uploader` and a SQLite-backed `MessageQueue`. Mirrors
    /// `configure(apiKey:autoTrack:logLevel:)` in every behaviour that
    /// matters for integration testing:
    ///   • marks the SDK as configured (idempotency holds)
    ///   • starts the queue runloop
    ///   • seeds an initial identify with device traits
    ///
    /// Tests construct their own SDKCore instance (not `.shared`) so state
    /// doesn't leak between tests, and supply a queue backed by a recording
    /// consumer to assert on emitted messages.
    func configureForTesting(
        identity: IdentityStore,
        queue: MessageQueue,
        contextProvider: ContextProvider,
        logger: any GalvaLogger = OSLogLogger(),
        minLogLevel: Galva.LogLevel = .debug
    ) async {
        guard !configured else {
            logger.warning(.configuration, "configureForTesting called more than once — ignoring")
            return
        }
        self.identity = identity
        self.queue = queue
        self.contextProvider = contextProvider
        // Mirror production: store the sink + level and rebuild the filter
        // through the same code path. Default `minLogLevel` is `.debug` so
        // tests see every breadcrumb out of the box. Later calls to
        // `installLogger(_:)` preserve the same filter level.
        installLogger(logger, minLevel: minLogLevel)
        setCachedEndUserId(identity.endUserId)
        setCachedAppAccountToken(identity.purchaseAttributionToken)
        await queue.startRunloop()
        configured = true
        self.logger.info(.configuration, "SDK configured (testing)", metadata: [
            "anonymousId": identity.anonymousId,
        ])
        // Seed identity with device traits, matching production behaviour.
        await identify(userId: nil, appAccountToken: nil, traits: nil)
    }
}
