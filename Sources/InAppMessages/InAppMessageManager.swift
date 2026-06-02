//
//  InAppMessageManager.swift
//  Galva
//
//  Polls /identities/communications on every foreground event, dedupes
//  against previously-seen messages, publishes the winning (newest) one to
//  the `InAppMessages.messages` stream, and warms the bundle cache so a
//  subsequent `show(in:)` doesn't block on network.
//
//  ┌────────────────────────────────────────────────────────────────────────┐
//  │  Where each piece of the in-app pipeline lives                          │
//  │                                                                         │
//  │   AppLifecycleObserver   foreground notification → poll()              │
//  │   APIClient              GET /identities/communications                │
//  │   InAppMessageStream     broadcast to developer's `for await`          │
//  │   WebViewBundleCache     warm-up download (best-effort)                │
//  │   InAppMessageManager    ← we orchestrate the above                    │
//  │   InAppMessagePresenter  consumed in show(message:) only — not here    │
//  └────────────────────────────────────────────────────────────────────────┘
//
//  Server-side priority resolution: the backend returns the highest-
//  priority pending message first. We don't re-rank on the client.
//

import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

@GalvaActor
final class InAppMessageManager {

    private let client: APIClient
    private let identity: IdentityStore
    private let stream: InAppMessageStream
    private let bundleCache: WebViewBundleCache
    private let initialization: InitializationManager
    private let logger: any GalvaLogger

    /// Guaranteed-delivery queue for `shouldRetry` apiFetch requests. `nil`
    /// when in-app messaging came up without it (shouldn't happen in
    /// production; nil-safe so tests can omit it).
    private let durableRequestQueue: DurableRequestQueue?

    /// Drop duplicate messages observed within the lifetime of the SDK
    /// process. Prevents a rapid background/foreground toggle from
    /// emitting the same message twice. Bounded — see prune below.
    private var seenIds: Set<String> = []

    /// Cached resolve payloads keyed by message id. Populated on `resolve`
    /// (or by a successful show flow) so that the bridge's
    /// `getMessageData()` call resolves immediately from memory.
    private(set) var resolvedPayloads: [String: ResolvedCommunication.Valid] = [:]

    /// The currently-displayed message id, if any. Used by `requestPurchase`
    /// in the bridge to enforce "offers can only be claimed in the context
    /// of a rendered message" (see docs).
    var activeMessageId: String?

    init(
        client: APIClient,
        identity: IdentityStore,
        stream: InAppMessageStream,
        bundleCache: WebViewBundleCache,
        initialization: InitializationManager,
        logger: any GalvaLogger,
        durableRequestQueue: DurableRequestQueue? = nil
    ) {
        self.client = client
        self.identity = identity
        self.stream = stream
        self.bundleCache = bundleCache
        self.initialization = initialization
        self.logger = logger
        self.durableRequestQueue = durableRequestQueue
    }

    // MARK: - Polling

    /// Hit GET /identities/communications, pick the newest unseen in-app
    /// message, publish it, and warm the bundle for its webview version.
    /// Idempotent — called by the lifecycle observer on every foreground.
    @discardableResult
    func poll() async -> [InAppMessages.Message] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "channelType", value: "in-app"),
        ]
        if let userId = identity.endUserId {
            query.append(URLQueryItem(name: "endUserId", value: userId))
        }
        // Always send anonymousId — pre-identify messages should still
        // resolve to the right device.
        query.append(URLQueryItem(name: "anonymousId", value: identity.anonymousId))

        do {
            let response: CommunicationListResponse = try await client.get(
                path: SDKConstants.communicationListPath,
                query: query
            )
            logger.debug(.identity, "in-app poll OK", metadata: [
                "count": String(response.data.count),
            ])
            return await dispatch(items: response.data)
        } catch let error as APIError {
            // Permanent errors typically mean missing/invalid api key on
            // this account — log and back off. Retryable errors (network
            // down, server 5xx) are normal during offline windows and ride
            // the next foreground event.
            let severity: Galva.LogLevel = error.isRetryable ? .info : .warning
            switch severity {
            case .warning:
                logger.warning(.identity, "in-app poll failed", error: error)
            default:
                logger.info(.identity, "in-app poll skipped (offline?)", error: error)
            }
            return []
        } catch {
            logger.warning(.identity, "in-app poll failed (unexpected)", error: error)
            return []
        }
    }

    /// Manually trigger a poll. Surfaces results synchronously to the
    /// caller while still publishing to the broadcast stream. Used by the
    /// public `InAppMessages.checkForMessages()` API.
    @discardableResult
    func checkForMessages() async -> [InAppMessages.Message] {
        await poll()
    }

    private func dispatch(items: [CommunicationItem]) async -> [InAppMessages.Message] {
        // Server returns highest-priority first, but consumers expect a
        // newest-first view per the doc. The two coincide today; keep the
        // server order to avoid second-guessing the priority resolution.
        var emitted: [InAppMessages.Message] = []
        for item in items where item.type == .trialRescueInApp {
            let key = item.id.uuidString.lowercased()
            if seenIds.contains(key) { continue }
            seenIds.insert(key)
            let message = item.toPublicMessage()
            emitted.append(message)
            // Hop to the MainActor stream — keeps message delivery on the
            // main thread for the SDK's MainActor-isolated consumers.
            await stream.yield(message)
            prefetchBundleIfPossible()
        }
        pruneSeenIfNeeded()
        return emitted
    }

    /// Warm the latest known bundle versions if we have any. We don't yet
    /// know which version the *resolve* step will pin until the developer
    /// actually calls show(message:), but per the docs we know the catalog
    /// of versions from /sdk/initialize — prefetching the newest is a
    /// reasonable bet and costs at most one HTTP GET that's already on the
    /// CDN's edge cache.
    private func prefetchBundleIfPossible() {
        guard let init_ = initialization.current,
              let latest = init_.webviewVersions.last else { return }
        Task { await bundleCache.prefetch(version: latest) }
    }

    private func pruneSeenIfNeeded() {
        // Cap at 1k entries — far more than any sane workflow surface,
        // and bounded so memory doesn't grow forever on a long-running app.
        guard seenIds.count > 1024 else { return }
        seenIds.removeAll(keepingCapacity: true)
    }

    // MARK: - Resolve

    /// Resolve a single message via POST /identities/communications/{id}/resolve.
    /// Returns a `Resolved` value with the payload + the webview version
    /// the SDK should load (server-pinned, with the latest known version
    /// from /sdk/initialize as a fallback), or `nil` when the server says
    /// `valid: false`.
    ///
    /// Called by the show(message:in:) flow before opening the WebView so
    /// that the bridge's `getMessageData()` request can be served from
    /// memory the moment the bundle finishes parsing.
    func resolve(messageId: String) async throws -> Resolved? {
        guard let messageUUID = UUID(uuidString: messageId) else {
            throw InAppMessageError.invalidMessageId
        }
        let path = SDKConstants.communicationResolvePath(messageId: messageUUID)
        let fallbackVersion = initialization.current?.webviewVersions.last

        // App Store storefront country code (ISO 3166-1 alpha-3) lets the
        // backend render storefront-aware copy / regional pricing into
        // the resolved payload. `nil` when StoreKit isn't reachable —
        // server treats that as "no storefront context".
        let territory = await currentStorefrontTerritory()

        let request = ResolveRequest(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            devicePlatform: .ios,
            bridgeProtocolVersion: SDKConstants.bridgeProtocolVersion,
            webviewVersion: fallbackVersion,
            billingContext: territory.map { ResolveRequest.BillingContext(territory: $0) }
        )
        let response: ResolveResponse = try await client.post(path: path, body: request)
        switch response.data {
        case .valid(let valid):
            resolvedPayloads[messageId] = valid
            // Pick the version: server pin > /sdk/initialize fallback >
            // hardcoded SDKConstants.fallbackWebviewVersion (used only when
            // both server config and the resolve response are silent, i.e.
            // truly offline first launch). This guarantees the show flow
            // always has a CDN URL to attempt.
            let chosenVersion = valid.webviewVersion
                ?? fallbackVersion
                ?? SDKConstants.fallbackWebviewVersion
            logger.debug(.identity, "in-app resolve OK", metadata: [
                "messageId": messageId,
                "version": chosenVersion,
            ])
            return Resolved(payload: valid, webviewVersion: chosenVersion)
        case .invalid:
            // Drop any stale cached payload — server has revoked.
            resolvedPayloads[messageId] = nil
            logger.info(.identity, "in-app resolve invalidated by server", metadata: [
                "messageId": messageId,
            ])
            return nil
        }
    }

    /// Outcome of `resolve` — the resolved payload plus the chosen
    /// `webviewVersion` (server pin > /sdk/initialize fallback).
    struct Resolved: Sendable, Hashable {
        let payload: ResolvedCommunication.Valid
        let webviewVersion: String
    }

    // MARK: - Active message tracking

    /// Set the active message id. Called by the presenter when a WebView
    /// becomes visible, and reset to `nil` on dismiss. The bridge consults
    /// this on every call to enforce "you can only request a purchase / read
    /// page context / read message data while an in-app message is on
    /// screen."
    func setActiveMessageId(_ id: String?) {
        activeMessageId = id
    }

    /// Accessor for the bridge layer (MainActor). Returns the current
    /// active id under a single actor hop.
    func currentActiveMessageId() -> String? { activeMessageId }

    /// Accessor for the bridge layer (MainActor). Returns the resolved
    /// payload for the given id, if cached.
    func payload(for messageId: String) -> ResolvedCommunication.Valid? {
        resolvedPayloads[messageId]
    }

    // MARK: - Reset

    /// Clear cached state. Called from `logOut()` so the next user's
    /// session doesn't see leftover messages from the previous identity.
    func reset() {
        seenIds.removeAll(keepingCapacity: false)
        resolvedPayloads.removeAll(keepingCapacity: false)
        activeMessageId = nil
    }

    // MARK: - StoreKit storefront

    /// Read the App Store storefront's country code (ISO 3166-1 alpha-3)
    /// for inclusion in the resolve request's `billingContext.territory`.
    /// Returns `nil` when StoreKit can't surface a storefront — Simulator
    /// without a `.storekit` config, user not signed into the App Store,
    /// or non-Apple build target. The server treats `nil` as "no
    /// storefront-specific rendering needed", so callers don't need to
    /// guard against it.
    private func currentStorefrontTerritory() async -> String? {
        #if canImport(StoreKit)
        return await Storefront.current?.countryCode
        #else
        return nil
        #endif
    }

    // MARK: - WebView API proxy (`apiFetch` bridge)

    /// Forward an `apiFetch` bridge call to the API client, which owns the
    /// base URL + API key and enforces the relative-path / same-origin
    /// guard. This lives on the manager because the bridge already routes
    /// every call through it and the manager holds the only `APIClient` the
    /// in-app stack has — no extra wiring through the WebView factory.
    /// Returns the raw HTTP outcome; the bridge maps it to the wire shape.
    func apiProxyFetch(
        path: String,
        method: String,
        body: Data?,
        additionalHeaders: [String: String]
    ) async throws -> APIClient.ProxyResponse {
        try await client.proxyRequest(
            path: path,
            method: method,
            body: body,
            additionalHeaders: additionalHeaders
        )
    }

    /// Persist a `shouldRetry` apiFetch for guaranteed eventual delivery and
    /// kick off a delivery attempt. Fire-and-forget — returns once the
    /// request is durably stored, not once it's delivered. Returns `false`
    /// when the durable queue isn't available (in-app messaging degraded),
    /// so the bridge can tell the bundle the request wasn't accepted.
    @discardableResult
    func enqueueDurableProxyRequest(
        path: String,
        method: String,
        body: Data?,
        additionalHeaders: [String: String]
    ) async -> Bool {
        guard let durableRequestQueue else {
            logger.warning(.uploader, "durable proxy unavailable — request not queued", metadata: [
                "method": method,
                "path": path,
            ])
            return false
        }
        await durableRequestQueue.enqueue(
            path: path,
            method: method,
            body: body,
            headers: additionalHeaders
        )
        return true
    }
}

// MARK: - Errors

enum InAppMessageError: Error, Sendable, Hashable {
    /// `show(message:)` received a malformed message id.
    case invalidMessageId
    /// `show(message:)` resolved but the server said the message is no
    /// longer valid (workflow exited, etc.).
    case messageNotFound
    /// Bundle download failed and no local copy exists for the requested
    /// webview version.
    case bundleUnavailable
    /// Negotiated bridge protocol incompatible with the installed SDK.
    case bridgeProtocolMismatch
    /// SDK has not been configured yet.
    case notConfigured
}
