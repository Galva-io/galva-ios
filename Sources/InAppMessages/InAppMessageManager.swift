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

@GalvaActor
final class InAppMessageManager {

    private let client: APIClient
    private let identity: IdentityStore
    private let stream: InAppMessageStream
    private let bundleCache: WebViewBundleCache
    private let initialization: InitializationManager
    private let logger: any GalvaLogger

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
        logger: any GalvaLogger
    ) {
        self.client = client
        self.identity = identity
        self.stream = stream
        self.bundleCache = bundleCache
        self.initialization = initialization
        self.logger = logger
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
            let key = item.id.uuidString
            if seenIds.contains(key) { continue }
            seenIds.insert(key)
            let message = item.toPublicMessage()
            emitted.append(message)
            stream.yield(message)
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
        let path = SDKConstants.communicationResolvePath
            .replacingOccurrences(of: "{id}", with: messageUUID.uuidString)
        let fallbackVersion = initialization.current?.webviewVersions.last
        let request = ResolveRequest(
            anonymousId: identity.anonymousId,
            endUserId: identity.endUserId,
            devicePlatform: .ios,
            bridgeProtocolVersion: SDKConstants.bridgeProtocolVersion,
            webviewVersion: fallbackVersion
        )
        let response: ResolveResponse = try await client.post(path: path, body: request)
        switch response.data {
        case .valid(let valid):
            resolvedPayloads[messageId] = valid
            guard let chosenVersion = valid.webviewVersion ?? fallbackVersion else {
                // Server didn't pin a version AND /sdk/initialize hasn't
                // landed yet — no bundle to load.
                throw InAppMessageError.bundleUnavailable
            }
            return Resolved(payload: valid, webviewVersion: chosenVersion)
        case .invalid:
            // Drop any stale cached payload — server has revoked.
            resolvedPayloads[messageId] = nil
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
