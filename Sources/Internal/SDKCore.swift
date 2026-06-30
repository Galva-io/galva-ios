//
//  SDKCore.swift
//  Galva
//
//  Internal singleton that owns all SDK state. The public API in Galva.swift
//  is a thin layer that hops onto `GalvaActor` and calls methods here.
//
//  ┌────────────────────────────────────────────────────────────────────────┐
//  │  Threading                                                              │
//  │  • Every mutable property is GalvaActor-isolated.                       │
//  │  • `cachedEndUserId` mirrors the identified user id in a lock so the    │
//  │    public synchronous getter `AppUser.identifiedUserId` can read it     │
//  │    from any thread without awaiting.                                    │
//  │                                                                         │
//  │  Lifecycle                                                              │
//  │  • configure() — captures the UI snapshot on MainActor, wires up        │
//  │                  IdentityStore + Uploader + MessageQueue.               │
//  │  • identify/track/logOut — enqueue a Message; queue does the rest.      │
//  │                                                                         │
//  │  All emits go through MessageQueue → UploadConsumer → Uploader → HTTP.  │
//  └────────────────────────────────────────────────────────────────────────┘
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif

@GalvaActor
final class SDKCore {

    nonisolated static let shared = SDKCore()

    /// `nonisolated` + internal so tests can construct fresh instances
    /// (the production singleton would otherwise accumulate state across
    /// tests). Production callers use `.shared`.
    nonisolated init() {}

    // MARK: State
    //
    // A few members below are deliberately `internal` rather than `private`
    // so that `SDKCore+Testing.swift` (a same-module extension) can wire
    // pre-built dependencies in without going through the production
    // `configure(apiKey:...)` path. Keep the *production* surface that
    // touches these members in this file; testing helpers live in the
    // extension.

    var configured = false
    private var apiKey: String?
    /// Selected backend (production / development / custom). Drives every
    /// URL the SDK touches — base API, webview bundle CDN.
    private(set) var environment: Galva.Environment = .production
    private var autoTrack: Galva.AutoTrackCategory = []
    private var logLevel: Galva.LogLevel = .warning

    var identity: IdentityStore?
    var queue: MessageQueue?
    private var uploader: Uploader?
    var contextProvider: ContextProvider?

    /// API client used for non-batch RPC calls (initialize, list/resolve
    /// communications, bundle download). Independent of the batch
    /// `Uploader` so the two surfaces evolve separately.
    var apiClient: APIClient?

    /// SDK initialization: caches the /sdk/initialize response and exposes
    /// the resolved data (webview versions, batch config, products) to the
    /// in-app message pipeline.
    var initializationManager: InitializationManager?

    /// In-app message manager — polling, payload resolution, stream
    /// fan-out. `nil` before configure() lands.
    var inAppMessageManager: InAppMessageManager?

    /// Guaranteed-delivery queue for `shouldRetry` apiFetch requests from
    /// the in-app message bundle. `nil` before configure() lands. Drained on
    /// configure (flush survivors) and every foreground.
    var durableRequestQueue: DurableRequestQueue?

    /// Broadcast hub for the `InAppMessages.messages` AsyncStream. Held
    /// here because `InAppMessages.messages` (a `static var`) needs a
    /// stable per-SDK reference across calls.
    let inAppMessageStream = InAppMessageStream()

    /// On-disk cache for WebView HTML bundles.
    var bundleCache: WebViewBundleCache?

    /// StoreKit warm-cache for product metadata referenced by in-app
    /// message offers. Populated after each successful /sdk/initialize
    /// refresh; the WebView presenter injects its current snapshot as
    /// `window.galvaProducts` on every present.
    #if canImport(StoreKit)
    var storeKitPrefetcher: StoreKitProductPrefetcher?
    #endif

    /// `Transaction.all` sweeper that posts
    /// `(originalTransactionId, userId)` mappings to Galva so organic
    /// purchases (native paywall, restored, family-shared) can be joined
    /// to the right user even when no `appAccountToken` made it onto the
    /// App Store receipt. See
    /// https://docs.galva.io/integrations/store-notifications/#user-mapping
    #if canImport(StoreKit)
    var transactionObserver: StoreKitTransactionObserver?
    #endif

    /// Foreground lifecycle observer driving the in-app message poller.
    /// Held to keep the registration alive across the SDK's lifetime.
    /// `nonisolated(unsafe)` because `AppLifecycleObserver` is `@MainActor`
    /// and we only ever assign / read it through GalvaActor code paths —
    /// the box is never mutated concurrently.
    nonisolated(unsafe) var lifecycleObserver: AppLifecycleObserver?

    /// Session tracker (auto-emits `session_start`). Created only when
    /// `autoTrackCategories` includes `.lifecycle` — `nil` otherwise so
    /// the foreground callback skips the dispatch entirely.
    var sessionTracker: SessionTracker?

    #if canImport(UIKit) && canImport(WebKit)
    /// WebView overlay presenter. Created lazily on first show(in:).
    /// `nonisolated(unsafe)` for the same reason as the lifecycle observer:
    /// `@MainActor`-isolated but stored from `@GalvaActor` configure().
    nonisolated(unsafe) var presenter: InAppMessagePresenter?
    #endif

    /// The configured "sink" — user-supplied or the default OSLog logger.
    /// Stored separately from `logger` because we need to re-wrap it in a
    /// `LevelFilterLogger` whenever the level OR the sink changes.
    private var sinkLogger: any GalvaLogger = OSLogLogger()

    /// Logger used by every SDK call site. Always a `LevelFilterLogger`
    /// wrapping `sinkLogger`. Recomputed when either dependency changes.
    var logger: any GalvaLogger = LevelFilterLogger(
        minLevel: .warning,
        wrapped: OSLogLogger()
    )

    /// Thread-safe mirror of the identified endUserId. Mutated whenever
    /// identify/logOut runs on GalvaActor; read by `AppUser.identifiedUserId`
    /// from any context without awaiting. The lock itself is nonisolated so
    /// the read path doesn't need to hop onto GalvaActor.
    nonisolated private static let _identifiedUserIdLock = NSLock()
    nonisolated(unsafe) private static var _identifiedUserId: String?

    /// Thread-safe mirror of the *resolved* StoreKit `appAccountToken` — the
    /// developer override from `identify(userId:appAccountToken:)` when set,
    /// otherwise the token Galva generates and attaches to its own purchases
    /// (the `anonymousId` rendered as a UUID). This is the exact value
    /// `IdentityStore.purchaseAttributionToken` hands to StoreKit, mirrored here
    /// so `AppUser.appAccountToken` can read it sync from any thread. Refreshed
    /// whenever configure/identify/logOut runs on GalvaActor; `nil` only before
    /// `configure()`.
    nonisolated private static let _appAccountTokenLock = NSLock()
    nonisolated(unsafe) private static var _appAccountToken: UUID?

    // MARK: Opt-out
    //
    // Persisted "do not track" flag with a lock-protected mirror so the
    // public `Galva.isOptedOut` accessor can read sync from any thread.
    // Same shape as `cachedEndUserId` above — load at configure(), mutate
    // through a GalvaActor-isolated setter, read via the lock.
    //
    // When opted out the SDK:
    //   • drops every `track` / `identify` / `createEndpoint` /
    //     `deleteEndpoint` / `setPreference` call silently
    //   • skips the auto-tracked `session_start` emission
    //   • skips `Transaction.all` sweeps
    //   • purges the persisted event queue on the false → true transition
    // In-app message polling + rendering keep working; opt-out blocks
    // server-bound telemetry, not user-visible feature delivery.

    nonisolated private static let _optedOutLock = NSLock()
    nonisolated(unsafe) private static var _optedOut: Bool = false
    /// `nonisolated` so the static load / set helpers (called from non-
    /// GalvaActor contexts during configure() bootstrap) can reach it.
    nonisolated static let optedOutDefaultsKey = "co.galva.optedOut"

    /// Lock-protected sync read of the persisted opt-out flag.
    nonisolated var isOptedOut: Bool {
        Self._optedOutLock.lock()
        defer { Self._optedOutLock.unlock() }
        return Self._optedOut
    }

    /// Set the cached + persisted opt-out flag. Returns `true` if the
    /// value actually changed (callers use this to decide whether to
    /// purge the queue / log).
    @discardableResult
    nonisolated static func setOptedOutFlag(
        _ value: Bool,
        defaults: UserDefaults = .standard
    ) -> Bool {
        _optedOutLock.lock()
        let changed = _optedOut != value
        _optedOut = value
        _optedOutLock.unlock()
        defaults.set(value, forKey: optedOutDefaultsKey)
        return changed
    }

    /// Load the persisted opt-out flag into the in-memory mirror. Called
    /// once at `configure()`.
    nonisolated static func loadOptedOutFlag(defaults: UserDefaults = .standard) {
        let value = defaults.bool(forKey: optedOutDefaultsKey)
        _optedOutLock.lock()
        _optedOut = value
        _optedOutLock.unlock()
    }

    /// GalvaActor-isolated entry point used by `Galva.setOptOut(_:)`.
    /// Persists the flag and purges the queue on the false → true
    /// transition so pre-existing events don't leak after the user opts
    /// out.
    func setOptedOut(_ value: Bool) async {
        let changed = Self.setOptedOutFlag(value)
        guard changed else { return }
        if value {
            // Drop everything still on disk so opting back in doesn't
            // resurrect events the user wanted ignored.
            try? await queue?.clearQueue()
            logger.info(.configuration, "opted out — event queue purged")
        } else {
            logger.info(.configuration, "opted back in")
        }
    }

    nonisolated var cachedEndUserId: String? {
        Self._identifiedUserIdLock.lock()
        defer { Self._identifiedUserIdLock.unlock() }
        return Self._identifiedUserId
    }

    func setCachedEndUserId(_ value: String?) {
        Self._identifiedUserIdLock.lock()
        Self._identifiedUserId = value
        Self._identifiedUserIdLock.unlock()
    }

    /// Lock-protected sync read of the resolved purchase `appAccountToken`
    /// (developer override or Galva's generated token). `nil` only before
    /// `configure()`. Mirror of `cachedEndUserId`.
    nonisolated var cachedAppAccountToken: UUID? {
        Self._appAccountTokenLock.lock()
        defer { Self._appAccountTokenLock.unlock() }
        return Self._appAccountToken
    }

    func setCachedAppAccountToken(_ value: UUID?) {
        Self._appAccountTokenLock.lock()
        Self._appAccountToken = value
        Self._appAccountTokenLock.unlock()
    }

    var currentEndUserId: String? { identity?.endUserId }
    var currentAnonymousId: String? { identity?.anonymousId }

    // MARK: Configure

    func configure(
        apiKey: String,
        environment: Galva.Environment = .production,
        autoTrack: Galva.AutoTrackCategory,
        logLevel: Galva.LogLevel,
        userLogger: (any GalvaLogger)? = nil
    ) async {
        guard !configured else {
            logger.warning(.configuration, "configure called more than once — ignoring")
            return
        }

        self.apiKey = apiKey
        self.environment = environment
        self.autoTrack = autoTrack
        self.logLevel = logLevel
        if let userLogger {
            self.sinkLogger = userLogger
        }
        rebuildLogger()

        // Load persisted opt-out flag into the in-memory mirror so the
        // public `Galva.isOptedOut` accessor returns the right value
        // from any thread before the next mutation.
        Self.loadOptedOutFlag()

        let identity = IdentityStore()
        self.identity = identity

        // Capture UI-bound system properties once on MainActor.
        let snapshot = await MainActor.run { DeviceSnapshot.capture() }
        // Seed the context with any device push token persisted from a previous
        // launch so `context.device.token` is populated from the first message.
        self.contextProvider = ContextProvider(deviceToken: identity.deviceToken, snapshot: snapshot)
        setCachedEndUserId(identity.endUserId)
        // Seed the resolved purchase token so `AppUser.appAccountToken` returns
        // the generated token (anonymousId-as-UUID) even before any identify().
        setCachedAppAccountToken(identity.purchaseAttributionToken)

        let uploader = Uploader(
            baseURL: environment.apiBaseURL,
            apiKey: apiKey,
            session: .shared,
            logger: logger
        )
        self.uploader = uploader

        let consumer = UploadConsumer(uploader: uploader, logger: logger)
        let queue = MessageQueue(
            consumer: consumer,
            options: .init(
                batchingWindow: .init(
                    timeWindow: SDKConstants.defaultFlushInterval,
                    maxCount: SDKConstants.defaultFlushAtCount
                ),
                maxStoredCount: SDKConstants.defaultMaxStoredMessages
            ),
            name: "default",
            logger: logger
        )
        self.queue = queue

        // Build the in-app messaging stack. Failures here log + skip — we
        // never block configure() on optional features.
        // Build the session tracker BEFORE the in-app messaging stack
        // wires up the foreground observer — that callback fans out to
        // sessionTracker?.handleForeground() so the tracker must be in
        // place when the first cold-start event fires.
        if autoTrack.contains(.lifecycle) {
            self.sessionTracker = SessionTracker(
                logger: logger,
                contextProvider: self.contextProvider ?? ContextProvider(),
                isOptedOut: { [weak self] in self?.isOptedOut ?? false },
                trackHandler: { [weak self] event in
                    await self?.track(event)
                }
            )
        }

        bootstrapInAppMessaging(
            apiKey: apiKey,
            environment: environment,
            identity: identity,
            logger: logger
        )

        await queue.startRunloop()
        configured = true
        logger.info(.configuration, "SDK configured", metadata: [
            "environment": String(describing: environment),
            "logLevel": String(describing: logLevel),
            "anonymousId": identity.anonymousId,
        ])

        // Seed built-in traits ($gv_timezone, $gv_languageCode) for the
        // current anonymous user so the server has them before any explicit
        // identify() call.
        await identify(userId: nil, appAccountToken: nil, traits: nil)

        // Resolve Apple Search Ads attribution (once per install) off the
        // configure path — it makes a network round-trip + may sleep between
        // 404 retries, so it must not block startup. The resolver persists the
        // result and emits an identify with the $gv_asa_* traits when matched.
        if autoTrack.contains(.appleSearchAds) {
            Task { @GalvaActor [weak self] in
                await self?.resolveAppleSearchAdsIfNeeded()
            }
        }

        // If we restored cached init data, apply its server-tuned batch
        // window to the freshly-built queue immediately — that way the
        // first session honors yesterday's tuning instead of running on
        // bare defaults until the refresh lands.
        if let cached = initializationManager?.current {
            queue.updateBatchingWindow(
                timeWindow: cached.batchCollection.flushInterval,
                maxCount: cached.batchCollection.flushAtCount
            )
        }

        // Kick off async /sdk/initialize refresh. On success, apply the
        // server-driven batch window so server-side load management is
        // genuinely remote-controlled, and warm the StoreKit cache so
        // offer pricing is ready by the time the first in-app message
        // opens.
        if let initManager = initializationManager {
            Task { @GalvaActor [weak self] in
                await initManager.refresh()
                guard let self,
                      let live = initManager.current else { return }
                if let queue = self.queue {
                    queue.updateBatchingWindow(
                        timeWindow: live.batchCollection.flushInterval,
                        maxCount: live.batchCollection.flushAtCount
                    )
                }
                #if canImport(StoreKit)
                self.storeKitPrefetcher?.prefetch(productIds: live.storekitProductIds)
                #endif
            }
        }
    }

    /// Wire up the InAppMessaging pipeline (API client, initialization
    /// cache, bundle cache, manager, lifecycle observer). Best-effort:
    /// any failure here only disables in-app messages; the core tracking
    /// pipeline keeps working.
    private func bootstrapInAppMessaging(
        apiKey: String,
        environment: Galva.Environment,
        identity: IdentityStore,
        logger: any GalvaLogger
    ) {
        let apiClient = APIClient(
            baseURL: environment.apiBaseURL,
            apiKey: apiKey,
            session: .shared,
            logger: logger
        )
        self.apiClient = apiClient

        // Initialization cache — non-fatal if the disk path can't be made.
        let initCache: InitializationCache?
        do {
            initCache = try InitializationCache()
        } catch {
            logger.warning(.configuration, "init cache disabled (no disk)", error: error)
            initCache = nil
        }
        let initManager = InitializationManager(
            client: apiClient,
            cache: initCache,
            logger: logger
        )
        initManager.loadCached() // synchronous; primes `current`
        self.initializationManager = initManager

        // Bundle cache — non-fatal if Caches/ isn't writable. CDN URL
        // follows the configured environment so production builds never
        // accidentally pull dev bundles (and vice versa).
        let bundleCache: WebViewBundleCache?
        do {
            bundleCache = try WebViewBundleCache(
                client: apiClient,
                cdnBaseURL: environment.webviewBundleCDN,
                logger: logger
            )
        } catch {
            logger.warning(.configuration, "bundle cache disabled (no disk)", error: error)
            bundleCache = nil
        }
        self.bundleCache = bundleCache

        // StoreKit warm-cache. Always available on Apple platforms; the
        // canImport guard is defensive for non-Apple builds (linux).
        #if canImport(StoreKit)
        self.storeKitPrefetcher = StoreKitProductPrefetcher(logger: logger)
        // Warm immediately if we have cached init data — yesterday's
        // catalog is a fine starting point on cold start. The refresh
        // task below will re-prefetch with fresh ids after the network.
        if let cached = initManager.current {
            self.storeKitPrefetcher?.prefetch(productIds: cached.storekitProductIds)
        }

        // Transaction observer — non-blocking. The first foreground
        // hook below kicks off `sweep()` which walks `Transaction.all`
        // and posts (originalTransactionId, userId) mappings so Galva's
        // backend can resolve organic / restored / family-shared
        // purchases that never see `appAccountToken`.
        self.transactionObserver = StoreKitTransactionObserver(
            client: apiClient,
            identity: identity,
            logger: logger
        )
        #endif

        // Durable retry queue for `shouldRetry` apiFetch requests. Owns its
        // own SQLite store (separate failure domain from the event queue) and
        // guarantees eventual delivery across outages + launches.
        let durableRequestQueue = DurableRequestQueue.makeDefault(
            client: apiClient,
            logger: logger
        )
        self.durableRequestQueue = durableRequestQueue
        // Flush any requests that survived the previous launch. Forced — a
        // fresh launch is a good moment to attempt immediately.
        Task { @GalvaActor in await durableRequestQueue.drain(force: true) }

        // Manager — only constructible if both bundleCache and initManager
        // came up. Without them in-app messaging cannot function.
        guard let bundleCache else { return }
        let manager = InAppMessageManager(
            client: apiClient,
            identity: identity,
            stream: inAppMessageStream,
            bundleCache: bundleCache,
            initialization: initManager,
            logger: logger,
            durableRequestQueue: durableRequestQueue
        )
        self.inAppMessageManager = manager

        // Foreground observer fans out to every SDK subsystem that
        // wakes on foreground: in-app message polling, the read-only
        // StoreKit transaction sweep, and the session tracker. All
        // three run on every foreground (cold start + return from
        // background); each gates internally on the relevant config.
        Task { @MainActor [weak self] in
            let observer = AppLifecycleObserver { [weak self] in
                Task { @GalvaActor in
                    guard let self else { return }
                    // session_start auto-emission (gated internally on
                    // .lifecycle category — sessionTracker is `nil`
                    // when the category isn't enabled).
                    await self.sessionTracker?.handleForeground()
                    // In-app message polling. Skipping when opted out
                    // would silently break a user-facing feature, so
                    // it keeps running.
                    await self.inAppMessageManager?.poll()
                    // Transaction observer is server-bound telemetry —
                    // skip when opted out so we don't leak originalIds.
                    #if canImport(StoreKit)
                    if !self.isOptedOut {
                        await self.transactionObserver?.sweep()
                    }
                    #endif
                    // Retry any durable apiFetch requests that failed earlier
                    // (network was down, app was killed mid-flight). Forced —
                    // foreground is a good moment to retry sooner than the
                    // backoff window, and it's naturally rate-limited. Not
                    // opt-out gated — these are bundle-initiated user actions,
                    // consistent with in-app messaging continuing under opt-out.
                    await self.durableRequestQueue?.drain(force: true)
                }
            }
            self?.lifecycleObserver = observer
            observer.start()
        }
    }

    /// Install a custom logger after configure. The level filter set at
    /// configure-time is preserved unless `minLevel` is also supplied.
    func installLogger(_ userLogger: any GalvaLogger, minLevel: Galva.LogLevel? = nil) {
        if let minLevel { self.logLevel = minLevel }
        self.sinkLogger = userLogger
        rebuildLogger()
        logger.info(.configuration, "custom logger installed")
    }

    /// Rebuild `logger` to wrap the current `sinkLogger` at the current
    /// `logLevel`. Called whenever either changes.
    private func rebuildLogger() {
        self.logger = LevelFilterLogger(minLevel: logLevel, wrapped: sinkLogger)
    }

    /// Handle a fresh APNs device token (hex). Persists it device-scoped,
    /// stamps it onto the message context, and registers it as a push
    /// endpoint for whoever is currently identified. The token belongs to the
    /// device, so the developer calls this once per launch — the SDK keeps it
    /// associated across login / logout on its own.
    func registerDeviceToken(_ token: String) async {
        guard let identity else {
            logger.warning(.identity, "device token received before configure() — dropping")
            return
        }
        identity.setDeviceToken(token)
        // Preserve the existing UI snapshot when updating the device token.
        let snapshot = contextProvider?.snapshot ?? .empty
        self.contextProvider = ContextProvider(deviceToken: token, snapshot: snapshot)
        logger.info(.identity, "device token registered")
        await registerCurrentDeviceTokenEndpoint()
    }

    /// (Re)register the device's stored push token as an endpoint for the
    /// CURRENT identity. Runs after a fresh token arrives and after any
    /// identity change (login / logout) so every user the device serves is
    /// reachable — the developer never re-sends the token per user. No-op
    /// when no token has been received yet.
    private func registerCurrentDeviceTokenEndpoint() async {
        guard let token = identity?.deviceToken else { return }
        await createEndpoint(.pushNotification(platform: .apns, token: token))
    }

    // MARK: Deep links

    /// A Galva deep link parsed before the SDK could act on it — e.g. an
    /// `openCommunication` link that arrived before the user was identified.
    /// Held until `configure()` + `identify()` make resolution possible, then
    /// replayed once by `resolveDeferredDeepLinkIfReady()`. Latest-wins: a
    /// newer deferred link replaces an unresolved older one. Readable in tests
    /// (`@testable`) to assert the defer → replay state machine.
    private(set) var deferredDeepLink: DeepLink?

    /// Router for incoming Galva deep links, forwarded from
    /// `Galva.handleOpenURL(_:)` (auto-attached by the SwiftUI
    /// `.galvaConfigure(...)` modifier, or called manually from UIKit). The
    /// caller has already confirmed the `gv` scheme; here we parse the URL
    /// into a typed `DeepLink` and route it — dispatching now, or deferring
    /// until the SDK can resolve it (see `route(_:)`).
    ///
    /// On a parse failure we log the detailed reason (unknown action, missing
    /// parameter, …) so a misconfigured campaign link is debuggable — but only
    /// the scheme + reason, never the full URL or parameter values, which can
    /// carry tokens.
    func handleOpenURL(_ url: URL) async {
        switch DeepLink.parse(url) {
        case .success(let link):
            await route(link)
        case .failure(let reason):
            logger.warning(.lifecycle, "deep link ignored", metadata: [
                "scheme": url.scheme ?? "<none>",
                "reason": reason.description,
            ])
        }
    }

    /// Dispatch a parsed deep link now, or defer it when the SDK can't resolve
    /// it yet. `openCommunication` resolves a user-targeted communication, so
    /// it needs an identified user — a link that arrives before `identify()`
    /// (or before `configure()`) is held and replayed by
    /// `resolveDeferredDeepLinkIfReady()` once identity is available.
    private func route(_ link: DeepLink) async {
        guard canResolve(link) else {
            deferredDeepLink = link
            logger.info(.lifecycle, "deep link deferred", metadata: [
                "action": link.actionName,
                "reason": configured ? "awaiting identify" : "awaiting configure",
            ])
            return
        }
        await dispatch(link)
    }

    /// Whether `link` can be resolved right now: `configure()` has run, and —
    /// for routes that target a specific user — the user is identified.
    private func canResolve(_ link: DeepLink) -> Bool {
        guard configured else { return false }
        if link.requiresIdentity, !isIdentified { return false }
        return true
    }

    /// `true` once the user has an end-user id (a real `identify(userId:)`,
    /// or a persisted id restored at `configure()`). Anonymous users are not
    /// identified.
    private var isIdentified: Bool { identity?.endUserId != nil }

    /// Dispatch a deep link to its route handler. The caller guarantees the
    /// link is resolvable (`canResolve`). Each `case` maps to a handler in a
    /// `DeepLink+<Route>.swift` extension.
    private func dispatch(_ link: DeepLink) async {
        logger.info(.lifecycle, "deep link", metadata: ["action": link.actionName])
        switch link {
        case let .openCommunication(communicationId, parameters):
            await handleOpenCommunication(communicationId: communicationId,
                                          parameters: parameters)
        }
    }

    /// Replay a deferred deep link once the SDK can resolve it — called after
    /// `identify()` (which `configure()` also invokes for the anonymous seed,
    /// covering a returning identified user whose id was restored from disk).
    /// No-op when nothing is pending or resolution still isn't possible.
    /// Clears the slot synchronously, then dispatches on a detached actor task
    /// so a long present flow never blocks the `identify()` / `configure()`
    /// caller.
    func resolveDeferredDeepLinkIfReady() {
        guard let deferred = deferredDeepLink, canResolve(deferred) else { return }
        deferredDeepLink = nil
        logger.info(.lifecycle, "resolving deferred deep link", metadata: [
            "action": deferred.actionName,
        ])
        Task { @GalvaActor [weak self] in
            await self?.dispatch(deferred)
        }
    }

    // MARK: Identify / Logout

    func identify(
        userId: String?,
        appAccountToken: UUID?,
        traits: [String: AnyJSONValue]?
    ) async {
        guard !isOptedOut else {
            logger.debug(.identity, "identify dropped (opted out)", metadata: [
                "userId": userId ?? "<none>",
            ])
            return
        }
        guard let queue, let identity, let contextProvider else {
            logger.warning(.identity, "identify called before configure() — dropping")
            return
        }
        logger.debug(.identity, "identify", metadata: [
            "userId": userId ?? "<none>",
            "hasTraits": traits.map { String($0.count) } ?? "0",
            "hasAccountToken": appAccountToken == nil ? "false" : "true",
        ])
        // Track whether this call is a real login transition (the user
        // binding actually changes) so we can re-associate the device push
        // token with the new user afterwards.
        var userDidChange = false
        if let userId {
            // Emit a higher-level state-transition log when the end-user
            // binding actually changes (was nil → now set, or switched users)
            // so the default-level trace can distinguish a real identify from
            // the per-trait-update calls that also flow through here.
            let previous = identity.endUserId
            if previous != userId {
                userDidChange = true
                logger.info(.identity, "endUserId changed", metadata: [
                    "from": previous ?? "<anonymous>",
                    "to": userId,
                ])
            }
            identity.setEndUserId(userId)
            setCachedEndUserId(userId)
        }

        var mergedTraits = traits ?? [:]
        // Reject an invalid email profile trait ($gv_email — set via
        // AppUser.set(.email, …)) at ingestion: drop just that key so a bad
        // address never reaches the server, while the rest of the identify
        // (userId, other traits) still goes through.
        if case .string(let email)? = mergedTraits[BuiltInTraitKey.email], !EmailValidator.isValid(email) {
            logger.warning(.identity, "identify — dropped invalid $gv_email trait")
            mergedTraits[BuiltInTraitKey.email] = nil
        }
        if let token = appAccountToken {
            // Persist on the identity store so StoreKit purchases pick
            // the override up automatically — not just sent as a trait.
            identity.setAppAccountToken(token)
            // Keep the public `AppUser.appAccountToken` mirror in step with the
            // override (resolves to `token` now that the override is set).
            setCachedAppAccountToken(identity.purchaseAttributionToken)
            mergedTraits[BuiltInTraitKey.appAccountToken] = .string(token.uuidString.lowercased())
        }
        // Auto-attach device-derived built-in traits on every identify so the
        // server sees them for both anonymous and identified users. Caller-
        // supplied values win — host apps with an in-app language/timezone
        // picker can pass `.timezone` / `.languageCode` to override.
        for (key, value) in Self.deviceTraits() {
            if mergedTraits[key] == nil {
                mergedTraits[key] = value
            }
        }
        // Re-attach resolved Apple Search Ads traits ($gv_asa_*) on every
        // identify so a later login carries the install's attribution. Distinct
        // key namespace, so this never collides with caller / device traits.
        for (key, value) in identity.appleSearchAdsTraits {
            if mergedTraits[key] == nil {
                mergedTraits[key] = value
            }
        }

        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .identify(traits: mergedTraits.isEmpty ? nil : mergedTraits)
        )
        await queue.emit(msg)

        // A new user just logged in — re-associate the device's push token
        // with them so they're reachable without the developer re-sending it.
        if userDidChange {
            await registerCurrentDeviceTokenEndpoint()
        }

        // A deep link may have arrived before we had an identity to resolve
        // its communication against. Now that identify has run, replay it if
        // resolution is possible (guarded inside — the anonymous seed identify
        // from configure() won't flush an identity-requiring link).
        resolveDeferredDeepLinkIfReady()
    }

    /// Built-in traits sourced from the device on every identify. Keys come
    /// from `BuiltInTraitKey` so they stay in sync with the OpenAPI `$gv_*`
    /// taxonomy and the typed `AppUserTraits` setters.
    private static func deviceTraits() -> [String: AnyJSONValue] {
        var out: [String: AnyJSONValue] = [
            BuiltInTraitKey.timezone: .string(TimeZone.current.identifier)
        ]
        if let lang = Locale.current.languageCode, !lang.isEmpty {
            out[BuiltInTraitKey.languageCode] = .string(lang)
        }
        return out
    }

    func logOut() async {
        guard let identity else {
            logger.warning(.identity, "logOut called before configure() — dropping")
            return
        }
        logger.info(.identity, "logOut", metadata: [
            "previousEndUserId": identity.endUserId ?? "<anonymous>",
        ])
        identity.setEndUserId(nil)
        identity.rotateAnonymousId()
        setCachedEndUserId(nil)
        // rotateAnonymousId() also cleared the override, so the resolved token
        // is now the fresh anonymousId-as-UUID — refresh the public mirror.
        setCachedAppAccountToken(identity.purchaseAttributionToken)
        // Clear in-memory caches scoped to the previous identity so the
        // post-logout anonymous user starts clean. In-app message dedupe
        // + resolved-payload cache wouldn't apply to the new user; the
        // transaction-observer dedupe must clear so the new anonymousId
        // gets the device's full historical mapping re-posted (the
        // server then aliases them onto whoever calls `identify` next).
        inAppMessageManager?.reset()
        #if canImport(StoreKit)
        transactionObserver?.reset()
        #endif
        // Seed built-in traits for the freshly-rotated anonymous user.
        await identify(userId: nil, appAccountToken: nil, traits: nil)
        // Re-associate the device's push token with the new anonymous identity
        // — the token is device-scoped, so the post-logout user stays reachable
        // without the developer re-sending it. (The seed identify above is a
        // nil-userId call, so it doesn't trigger the login-transition path.)
        await registerCurrentDeviceTokenEndpoint()
    }

    // MARK: Transaction reconciliation

    /// Force an off-cycle sweep of `Transaction.all` and re-post the
    /// `(originalTransactionId, userId)` mapping table. Normal operation
    /// never needs this — the foreground lifecycle covers every
    /// transaction the device can see. Use it for:
    ///   • Tight-loop billing flows that complete in the same session
    ///     a foreground event would naturally cover (e.g. user just
    ///     finished a host-app paywall checkout and we want the bundle
    ///     to read fresh entitlement immediately).
    ///   • Support workflows that need a "Restore Purchases" guarantee.
    /// Idempotent: safe to call repeatedly.
    func reconcileTransactions() async {
        guard !isOptedOut else {
            logger.debug(.identity, "reconcileTransactions skipped (opted out)")
            return
        }
        #if canImport(StoreKit)
        await transactionObserver?.sweep()
        #endif
    }

    // MARK: Track

    /// Emit a strongly-typed event (`AppEvents.Event`). Mirrors the public
    /// `AppEvents.track(_:)` but on this instance so internal callers (e.g.
    /// `SessionTracker` emitting `SessionStartEvent`) go through the typed path.
    /// Built-in events live in `BuiltInEvents.swift`.
    func track<E: AppEvents.Event>(_ event: E) async {
        await track(event: event.eventName, properties: event.attributes?.mapValues { AnyJSONValue($0) })
    }

    func track(event: String, properties: [String: AnyJSONValue]?) async {
        guard !isOptedOut else {
            logger.debug(.identity, "track dropped (opted out)", metadata: ["event": event])
            return
        }
        guard let queue, let identity, let contextProvider else {
            logger.warning(.identity, "track called before configure() — dropping", metadata: ["event": event])
            return
        }
        logger.debug(.identity, "track", metadata: [
            "event": event,
            "propsCount": properties.map { String($0.count) } ?? "0",
        ])
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .track(event: event, properties: properties, sourceType: nil, sourceId: nil)
        )
        await queue.emit(msg)
    }

    // MARK: Communication endpoints

    func createEndpoint(_ endpoint: CommunicationEndpoint) async {
        guard !isOptedOut else {
            logger.debug(.identity, "createEndpoint dropped (opted out)", metadata: [
                "channel": endpoint.channelType.rawValue,
            ])
            return
        }
        guard let queue, let identity, let contextProvider else {
            logger.warning(.identity, "createEndpoint called before configure() — dropping")
            return
        }
        // Reject an invalid email at ingestion so it never reaches the server
        // (mirrors the backend's validation). Don't log the address itself — PII.
        if case .email(let address) = endpoint, !EmailValidator.isValid(address) {
            logger.warning(.identity, "createEndpoint dropped — invalid email address")
            return
        }
        logger.debug(.identity, "createEndpoint", metadata: [
            "channel": endpoint.channelType.rawValue,
        ])
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .createCommunicationEndpoint(endpoint)
        )
        await queue.emit(msg)
    }

    func deleteEndpoint(_ endpoint: CommunicationEndpoint) async {
        guard !isOptedOut else {
            logger.debug(.identity, "deleteEndpoint dropped (opted out)", metadata: [
                "channel": endpoint.channelType.rawValue,
            ])
            return
        }
        guard let queue, let identity, let contextProvider else {
            logger.warning(.identity, "deleteEndpoint called before configure() — dropping")
            return
        }
        // Same validation as create — never send a malformed address upstream.
        if case .email(let address) = endpoint, !EmailValidator.isValid(address) {
            logger.warning(.identity, "deleteEndpoint dropped — invalid email address")
            return
        }
        logger.debug(.identity, "deleteEndpoint", metadata: [
            "channel": endpoint.channelType.rawValue,
        ])
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .deleteCommunicationEndpoint(endpoint)
        )
        await queue.emit(msg)
    }

    // MARK: In-app messages

    #if canImport(UIKit) && canImport(WebKit)
    /// Drive the WebView overlay for a single message. Throws if the
    /// SDK is not configured or the bundle / payload can't be resolved.
    func showInAppMessage(
        _ message: InAppMessages.Message,
        in scene: UIWindowScene? = nil,
        deepLinkParameters: [String: String] = [:]
    ) async throws {
        guard configured,
              let manager = inAppMessageManager,
              let bundleCache,
              let identity else {
            throw InAppMessages.Error.notConfigured
        }
        let snapshotLogger = logger

        // Snapshot the current StoreKit product summary on the GalvaActor
        // BEFORE hopping to MainActor — the prefetcher is actor-isolated.
        // It crosses as `[String: AnyJSONValue]` (a Sendable, structured JSON
        // value), NOT a pre-serialized string: the presenter / factory owns
        // serialization at the `window.galvaProducts` injection boundary.
        #if canImport(StoreKit)
        let products = storeKitPrefetcher?.currentSummaryObject() ?? [:]
        #else
        let products: [String: AnyJSONValue] = [:]
        #endif

        // Snapshot the prefetcher reference too — it crosses the hop as
        // a sendable reference (GalvaActor-isolated class, but reference
        // passing is safe; we only call its methods through await).
        #if canImport(StoreKit)
        let prefetcher = self.storeKitPrefetcher
        #endif

        // Hop to MainActor to construct / reuse the presenter. The
        // presenter then runs its async show() on the main actor.
        try await MainActor.run {
            let presenter: InAppMessagePresenter
            if let existing = self.presenter {
                presenter = existing
            } else {
                #if canImport(StoreKit)
                presenter = InAppMessagePresenter(
                    messageManager: manager,
                    identity: identity,
                    bundleCache: bundleCache,
                    storeKitPrefetcher: prefetcher,
                    logger: snapshotLogger
                )
                #else
                presenter = InAppMessagePresenter(
                    messageManager: manager,
                    identity: identity,
                    bundleCache: bundleCache,
                    logger: snapshotLogger
                )
                #endif
                self.presenter = presenter
            }
            return presenter
        }.show(
            message: message,
            in: scene,
            prefetchedProducts: products,
            deepLinkParameters: deepLinkParameters
        )
    }

    /// SwiftUI entry point. Resolves the message payload, downloads the
    /// HTML bundle, snapshots the StoreKit product catalog, and builds
    /// the `WKWebView` + `NativeBridge` on the main actor — then hands
    /// them back to the SwiftUI coordinator (which mounts the WebView
    /// inside `.sheet(item:)` via a `UIViewRepresentable`).
    ///
    /// Unlike `showInAppMessage(_:in:)`, this method does NOT call
    /// UIKit's `present(animated:)` — SwiftUI owns the sheet
    /// presentation. The `host` is wired into the bridge so
    /// `galva.ready()` and `galva.dismiss(reason:)` route back into the
    /// coordinator's `@Published` state and dismissal binding.
    ///
    /// Throws `InAppMessages.Error` on failure: `notConfigured`,
    /// `messageNotFound`, or `bundleUnavailable`. The caller surfaces
    /// these by clearing the presenting binding (which dismisses the
    /// sheet).
    func prepareInAppMessage(
        _ message: InAppMessages.Message,
        host: any InAppMessageHost
    ) async throws -> PreparedInAppMessage {
        guard configured,
              let manager = inAppMessageManager,
              let bundleCache,
              let identity else {
            throw InAppMessages.Error.notConfigured
        }
        let snapshotLogger = logger

        // 1. Resolve payload — also caches it for the bridge's
        //    `getMessageData()` to serve immediately.
        let resolved = try await manager.resolve(messageId: message.id)
        guard let resolved else {
            throw InAppMessages.Error.messageNotFound
        }

        // 2. Resolve / download the bundle file URL.
        let bundleURL: URL
        do {
            bundleURL = try await bundleCache.bundleURL(for: resolved.webviewVersion)
        } catch {
            throw InAppMessages.Error.bundleUnavailable
        }

        // 3. Snapshot StoreKit products + prefetcher reference on the
        //    GalvaActor before crossing to MainActor. Products cross as a
        //    Sendable `[String: AnyJSONValue]`; the factory serializes them
        //    at the `window.galvaProducts` injection boundary.
        #if canImport(StoreKit)
        let products = storeKitPrefetcher?.currentSummaryObject() ?? [:]
        let prefetcher = self.storeKitPrefetcher
        #else
        let products: [String: AnyJSONValue] = [:]
        #endif

        // 4. Mark active so the bridge's getPageContext / getMessageData
        //    / requestPurchase calls all see this id. Synchronous —
        //    we're already on the GalvaActor with the manager.
        manager.setActiveMessageId(message.id)

        // 5. Build the WebView + bridge on the main actor, load the
        //    file URL, and hand the pair back. The coordinator retains
        //    both for the lifetime of the sheet.
        return await MainActor.run {
            #if canImport(StoreKit)
            let (webView, bridge) = InAppMessageWebViewFactory.make(
                messageManager: manager,
                identity: identity,
                storeKitPrefetcher: prefetcher,
                host: host,
                prefetchedProducts: products,
                logger: snapshotLogger
            )
            #else
            let (webView, bridge) = InAppMessageWebViewFactory.make(
                messageManager: manager,
                identity: identity,
                host: host,
                prefetchedProducts: products,
                logger: snapshotLogger
            )
            #endif
            webView.loadFileURL(
                bundleURL,
                allowingReadAccessTo: bundleURL.deletingLastPathComponent()
            )
            snapshotLogger.info(.identity, "SwiftUI sheet preparing", metadata: [
                "messageId": message.id,
                "version": resolved.webviewVersion,
            ])
            return PreparedInAppMessage(webView: webView, bridge: bridge)
        }
    }

    /// Clear the active message id. Called by the SwiftUI coordinator on
    /// dismiss so the bridge doesn't serve stale `getMessageData()` /
    /// `requestPurchase` calls to a sheet that's already off screen.
    func clearActiveMessage() async {
        inAppMessageManager?.setActiveMessageId(nil)
    }
    #endif

    func setPreference(
        channel: CommunicationEndpoint.ChannelType,
        disabled: Bool?,
        categories: [String: Bool]?
    ) async {
        guard !isOptedOut else {
            logger.debug(.identity, "setPreference dropped (opted out)", metadata: [
                "channel": channel.rawValue,
            ])
            return
        }
        guard let queue, let identity, let contextProvider else {
            logger.warning(.identity, "setPreference called before configure() — dropping")
            return
        }
        logger.debug(.identity, "setPreference", metadata: [
            "channel": channel.rawValue,
            "disabled": disabled.map(String.init(describing:)) ?? "<unset>",
            "categoryCount": String(categories?.count ?? 0),
        ])
        let msg = Message(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            context: contextProvider.currentContext(),
            body: .setCommunicationPreference(
                channelType: channel,
                disabled: disabled,
                categories: categories
            )
        )
        await queue.emit(msg)
    }
}
