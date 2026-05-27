//
//  StoreKitTransactionObserver.swift
//  Galva
//
//  Reports `(originalTransactionId, userId / anonymousId)` mappings to
//  Galva's backend so that App Store Server Notifications which arrive
//  WITHOUT a matching `appAccountToken` — organic purchases, native
//  paywall transactions, restored purchases, Family Sharing grants,
//  anything wired up before `identify(userId:)` was called — can still
//  be joined to the correct Galva end user.
//
//  Why this is necessary
//  ─────────────────────
//  Apple's `appAccountToken` is only present on the storefront receipt
//  when the calling code passed it on `Product.purchase(options:)`. The
//  SDK does that for offers redeemed through `requestPurchase`, but the
//  host app's existing paywall (or any third-party SDK that runs its
//  own checkout) typically does not. Those transactions arrive at
//  Galva's webhook with no `appAccountToken` field. The fallback join
//  is `originalTransactionId` — Galva needs the SDK to teach the
//  backend "this device with userId=X has seen originalTransactionId=Y"
//  so the next webhook can resolve to the right user.
//
//  Read-only sweep
//  ───────────────
//  • Iterates `Transaction.all`, NOT `Transaction.updates`.
//    `Transaction.updates` is single-broadcast — if the host app's
//    listener (RevenueCat, in-house, whatever) drains it first, a second
//    observer sees nothing. `Transaction.all` is idempotent and
//    re-readable per foreground, so the sweep is safe alongside any
//    existing StoreKit pipeline.
//  • Does NOT call `transaction.finish()`. The host app's existing
//    observer owns lifecycle. We're a passive mapping emitter only.
//  • Does NOT refresh entitlements, validate receipts, or call back
//    into the host app. Nothing about StoreKit state ownership shifts.
//
//  Cadence
//  ───────
//  • Sweeps on every foreground (cold start + return from background)
//    via `AppLifecycleObserver` in SDKCore.
//  • Plus on demand via `Galva.reconcileTransactions()` — useful right
//    after the host billing observer acknowledges a transaction inside
//    the same session (no foreground transition will happen between
//    the purchase and the bundle consuming entitlement).
//
//  Idempotency
//  ───────────
//  • Reported originalTransactionIds are kept in an in-memory set so
//    we don't hammer the server with the same mapping every foreground.
//    Cleared on logout — the new anonymous user re-observes the
//    device's history fresh so the server can alias them onto the
//    fresh anonymousId.
//

import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(StoreKit)

@GalvaActor
final class StoreKitTransactionObserver {

    private let client: APIClient
    private let identity: IdentityStore
    private let logger: any GalvaLogger

    /// originalTransactionIds reported in the current session. Bounded;
    /// `reset()` (called from `logOut`) clears it so the post-logout
    /// anonymous user re-observes the device's purchase history.
    private var reportedIds: Set<UInt64> = []

    /// In-flight sweep task. Used to coalesce concurrent foreground +
    /// manual reconcile calls so we don't run two `Transaction.all`
    /// iterations in parallel.
    private var inFlight: Task<Void, Never>?

    init(
        client: APIClient,
        identity: IdentityStore,
        logger: any GalvaLogger
    ) {
        self.client = client
        self.identity = identity
        self.logger = logger
    }

    // MARK: - Public

    /// Walk `Transaction.all`, POST every new mapping to
    /// `/v1/transactions/observe`. Idempotent across calls; concurrent
    /// invocations share the in-flight sweep.
    func sweep() async {
        if let inFlight {
            await inFlight.value
            return
        }
        // Explicit `Task<Void, Never>` so the optional-chain return
        // (`self?.performSweep()` is `Void?`) collapses to `Void` for
        // the task's Success generic.
        let task = Task<Void, Never> { @GalvaActor [weak self] in
            guard let self else { return }
            await self.performSweep()
        }
        inFlight = task
        defer { inFlight = nil }
        await task.value
    }

    /// Clear the dedupe set. Called from `SDKCore.logOut()` so the new
    /// anonymous user re-observes the device's full history (and the
    /// server can alias each mapping to the fresh anonymousId).
    func reset() {
        reportedIds.removeAll(keepingCapacity: false)
    }

    // MARK: - Sweep

    private func performSweep() async {
        let anonymousId = identity.anonymousId
        let endUserId = identity.endUserId

        // Snapshot the existing dedupe set so we can revert it on
        // network failure — we only consider mappings "reported" after
        // the server acks them.
        var fresh: [String] = []
        for await result in Transaction.all {
            let transaction: Transaction
            switch result {
            case .verified(let t):
                transaction = t
            case .unverified(let t, _):
                // Per the docs the sweep is "purely a mapping emitter"
                // and does not validate receipts. Unverified transactions
                // (revoked, tampered, unfinished sandbox) still have a
                // legitimate `originalID` we want the server to know about
                // — verification of the actual receipt happens in
                // Apple's own server-to-server notification flow.
                transaction = t
            }
            let original = transaction.originalID
            // Skip ids we've already reported this session.
            guard reportedIds.insert(original).inserted else { continue }
            fresh.append(String(original))
        }

        guard !fresh.isEmpty else {
            logger.debug(.identity, "transaction sweep: nothing new")
            return
        }

        let request = ObserveTransactionsRequest(
            anonymousId: anonymousId,
            endUserId: endUserId,
            transactions: fresh.map { .init(originalTransactionId: $0) }
        )

        do {
            let _: EmptyAPIResponse = try await client.post(
                path: SDKConstants.transactionsObservePath,
                body: request
            )
            logger.info(.identity, "transactions observed", metadata: [
                "count": String(fresh.count),
                "endUserId": endUserId ?? "<anonymous>",
            ])
        } catch let error as APIError {
            // Network/server failure — un-mark so a future sweep retries.
            // Permanent failures (auth) won't fix themselves, but the
            // mapping table is server-side idempotent so a retry the
            // next foreground is benign.
            for raw in fresh {
                if let id = UInt64(raw) { reportedIds.remove(id) }
            }
            let severity: Galva.LogLevel = error.isRetryable ? .info : .warning
            switch severity {
            case .warning:
                logger.warning(.identity, "transactions observe failed", error: error)
            default:
                logger.info(.identity, "transactions observe skipped (offline?)", error: error)
            }
        } catch {
            for raw in fresh {
                if let id = UInt64(raw) { reportedIds.remove(id) }
            }
            logger.warning(.identity, "transactions observe failed (unexpected)", error: error)
        }
    }
}

// MARK: - Wire format

/// Wire payload for `POST /v1/transactions/observe`. Per-transaction
/// payload is intentionally minimal — the server uses
/// `originalTransactionId` as the join key against Apple's notifications,
/// and the `(anonymousId, endUserId)` pair on the envelope tells it who
/// to attribute the mapping to.
struct ObserveTransactionsRequest: Sendable, Codable, Hashable {
    let anonymousId: String
    let endUserId: String?
    let transactions: [Mapping]

    struct Mapping: Sendable, Codable, Hashable {
        let originalTransactionId: String
    }
}

/// Permissive Decodable used as the response type for fire-and-forget
/// RPCs — we don't read fields, just want to confirm a 2xx. Accepts any
/// JSON body (empty, `{}`, full meta/data envelope) without throwing.
struct EmptyAPIResponse: Decodable, Sendable {
    init(from decoder: Decoder) throws {
        // Try once; swallow shape mismatches because we don't care.
        _ = try? decoder.singleValueContainer().decode(AnyJSONValue.self)
    }
}

#endif // canImport(StoreKit)
