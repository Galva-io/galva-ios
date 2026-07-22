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

    /// Message ids that actually went ON SCREEN this run (deep-link,
    /// programmatic, or auto-display). A presented communication must never
    /// re-present — not via a later poll (it also joins `seenIds`) and not via
    /// a re-fired `openCommunication` deep link (SwiftUI can re-deliver the
    /// same URL on scene reactivation; the deep-link route checks
    /// `hasPresented` and stands down WITHOUT claiming the display budget, so
    /// other messages stay eligible).
    private var presentedIds: Set<String> = []

    /// Cached resolve payloads keyed by message id. Populated on `resolve`
    /// (or by a successful show flow) so that the bridge's
    /// `getMessageData()` call resolves immediately from memory.
    private(set) var resolvedPayloads: [String: ResolvedCommunication.Valid] = [:]

    /// The currently-displayed message id, if any. Used by `requestPurchase`
    /// in the bridge to enforce "offers can only be claimed in the context
    /// of a rendered message" (see docs).
    var activeMessageId: String?

    // MARK: - Display budget (one message per foreground stint)
    //
    // At most ONE in-app message flow per "return event" (cold start, resume
    // from background, or an explicit `checkForMessages()`):
    //
    //   • `.pending`   a deep-link / programmatic show is resolving — polling
    //                  must not fetch AT ALL (a deep link is user-initiated and
    //                  outranks anything the poll could surface).
    //   • `.used`      a message was delivered/presented this stint — no more
    //                  fetches until the next return event.
    //
    // Because the manager is `@GalvaActor`, the deep-link claim and the poll's
    // slot checks are serialized by the actor — a claim that lands while a
    // fetch is in flight is observed by the post-fetch re-check, and the
    // fetched items are dropped UNMARKED so they surface again next stint.
    // This is what prevents an email deep link and a foreground poll from
    // ever presenting two messages at once.

    enum DisplaySlot: Sendable, Hashable {
        case available
        /// Deep-link / programmatic presentation resolving. Fetch suppressed.
        case pending(messageId: String)
        /// A message was delivered or presented this stint. Fetch suppressed
        /// until the next return event resets.
        case used(messageId: String)
    }

    private(set) var displaySlot: DisplaySlot = .available

    /// Claim the stint's display slot for a deep-link / programmatic show.
    /// Priority claim: overrides `.used` (the user explicitly asked for this
    /// message). No-op when the same message is already on screen, so a
    /// repeated `show(in:)` doesn't regress `.used` back to `.pending`.
    func claimDisplaySlot(messageId: String) {
        guard activeMessageId != messageId else { return }
        displaySlot = .pending(messageId: messageId)
    }

    /// Roll back a claim whose presentation failed (resolve rejected, bundle
    /// unavailable, no host) — nothing was shown, so the stint's budget is
    /// restored and the next poll may fetch again.
    func releaseDisplaySlot(messageId: String) {
        switch displaySlot {
        case .pending(let id) where id == messageId:
            displaySlot = .available
        case .used(let id) where id == messageId && activeMessageId == nil:
            // The show consumed the slot (setActiveMessageId ran) but then
            // failed and tore down before returning — restore the budget.
            displaySlot = .available
        default:
            break
        }
    }

    /// Start-of-stint reset, called from `poll()` (which only runs on return
    /// events + explicit checks). A spent slot resets ONLY when nothing is
    /// pending or still on screen — so a deep link claimed before the
    /// foreground poll, or a sheet the user is still viewing, keeps polling
    /// suppressed.
    private func resetDisplaySlotIfStale() {
        if case .used = displaySlot, activeMessageId == nil {
            displaySlot = .available
        }
    }

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

    /// Hit GET /identities/communications, pick the FIRST unseen in-app
    /// message (server returns highest-priority first), publish it, and warm
    /// the bundle for its webview version. Called by the lifecycle observer on
    /// every foreground (a "return event") and by `checkForMessages()`.
    ///
    /// Display budget: at most one message per stint. The fetch is skipped
    /// entirely while a deep-link presentation is pending/on screen or a
    /// message already showed this stint; the skipped messages surface
    /// naturally on the next return event's poll.
    @discardableResult
    func poll() async -> [InAppMessages.Message] {
        // A return event starts a fresh stint (unless something is pending
        // or still on screen).
        resetDisplaySlotIfStale()
        guard case .available = displaySlot else {
            logger.debug(.identity, "in-app poll skipped — display slot busy", metadata: [
                "slot": String(describing: displaySlot),
            ])
            return []
        }
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
            // Re-check after the network suspension: a deep link may have
            // claimed the slot while the fetch was in flight (the actor
            // serializes the claim and this check). Drop the results UNMARKED
            // so they surface again on the next return event's poll.
            guard case .available = displaySlot else {
                logger.info(.identity, "in-app poll dropped — display slot claimed mid-flight", metadata: [
                    "count": String(response.data.count),
                ])
                return []
            }
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
        // Deliver exactly ONE message per stint — the first unseen in-app item
        // in server order (the backend returns highest-priority first). The
        // remaining items are left UNMARKED so they surface on the next return
        // event's poll instead of being lost.
        for item in items {
            let key = item.id.uuidString.lowercased()
            if seenIds.contains(key) { continue }
            seenIds.insert(key)
            let message = item.toPublicMessage()
            // Consume the stint's budget at delivery — the fetch won't run
            // again until the next return event, even if the app never
            // presents this message.
            displaySlot = .used(messageId: message.id)
            // Hop to the MainActor stream — keeps message delivery on the
            // main thread for the SDK's MainActor-isolated consumers.
            await stream.yield(message)
            prefetchBundleIfPossible()
            pruneSeenIfNeeded()
            return [message]
        }
        pruneSeenIfNeeded()
        return []
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
        // A presentation going live consumes the stint's display budget —
        // this also converts a deep link's `.pending` claim to `.used`.
        // Going nil (dismiss) does NOT free the slot; the budget stays spent
        // until the next return event resets it.
        if let id {
            displaySlot = .used(messageId: id)
            // Once shown, this communication is done for the run: later polls
            // must not re-deliver it (seenIds) and a repeated deep link must
            // not re-present it (presentedIds) — clearing the way for OTHER
            // pending messages instead.
            presentedIds.insert(id)
            seenIds.insert(id)
        }
    }

    /// Whether `messageId` already went on screen this run. Consulted by the
    /// `openCommunication` deep-link route so a re-fired URL doesn't re-present
    /// a message the user already saw (or burn the display budget doing so).
    func hasPresented(messageId: String) -> Bool {
        presentedIds.contains(messageId)
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
        presentedIds.removeAll(keepingCapacity: false)
        resolvedPayloads.removeAll(keepingCapacity: false)
        activeMessageId = nil
        displaySlot = .available
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
