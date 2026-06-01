//
//  IdentityStore.swift
//  Galva
//
//  Owns the two ids attached to every outgoing message:
//
//    • anonymousId — UUID v7, generated on first launch. Always present.
//                    Rotated on logOut() so a re-anonymized user gets a
//                    fresh session id.
//    • endUserId   — your app's user id. nil until identify() is called,
//                    nil again after logOut().
//
//  Persistence: UserDefaults under the standard suite. Tiny payload, fast
//  reads, survives app updates and reinstalls within the same data container.
//

import Foundation

@GalvaActor
final class IdentityStore {
    nonisolated(unsafe) private let defaults: UserDefaults
    private static let anonymousIdKey       = "co.galva.anonymousId"
    private static let endUserIdKey         = "co.galva.endUserId"
    private static let appAccountTokenKey   = "co.galva.appAccountToken"

    private(set) var anonymousId: String
    private(set) var endUserId: String?

    /// Developer-supplied StoreKit `appAccountToken` override. Set via
    /// `AppUser.identify(userId:appAccountToken:)`. `nil` when the host
    /// app hasn't supplied one — the SDK then falls back to deriving the
    /// attribution token from `anonymousId` (see
    /// `purchaseAttributionToken` below).
    private(set) var appAccountToken: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let existing = defaults.string(forKey: Self.anonymousIdKey) {
            // Canonicalize to lowercase (RFC 4122 / Galva wire convention) and
            // migrate older installs that persisted `UUID.uuidString`'s default
            // uppercase form. Same logical UUID, single case on the wire.
            let canonical = existing.lowercased()
            if canonical != existing {
                defaults.set(canonical, forKey: Self.anonymousIdKey)
            }
            anonymousId = canonical
        } else {
            let new = UUIDv7.next().uuidString.lowercased()
            defaults.set(new, forKey: Self.anonymousIdKey)
            anonymousId = new
        }

        endUserId = defaults.string(forKey: Self.endUserIdKey)
        if let raw = defaults.string(forKey: Self.appAccountTokenKey) {
            appAccountToken = UUID(uuidString: raw)
        }
    }

    func setEndUserId(_ id: String?) {
        endUserId = id
        if let id {
            defaults.set(id, forKey: Self.endUserIdKey)
        } else {
            defaults.removeObject(forKey: Self.endUserIdKey)
        }
    }

    /// Persist (or clear) the developer-supplied `appAccountToken`. Called
    /// from `SDKCore.identify` so the token survives app restarts and is
    /// available to `Product.purchase(options:)` without an additional
    /// identify call.
    func setAppAccountToken(_ token: UUID?) {
        appAccountToken = token
        if let token {
            defaults.set(token.uuidString.lowercased(), forKey: Self.appAccountTokenKey)
        } else {
            defaults.removeObject(forKey: Self.appAccountTokenKey)
        }
    }

    /// UUID to attach as `appAccountToken` on every Galva-initiated
    /// StoreKit purchase. Resolution order:
    ///
    ///   1. Developer override set via `identify(userId:appAccountToken:)`.
    ///   2. The auto-generated `anonymousId` parsed as a UUID — already
    ///      a valid UUID (we always mint it via `UUIDv7.next()`).
    ///   3. A freshly-minted UUID — defensive fallback that should never
    ///      hit in practice; included so the call site can rely on a
    ///      non-optional value.
    ///
    /// Apple silently drops `appAccountToken` values that aren't valid
    /// UUIDs, so steps 1 + 2 are the only paths that matter. The
    /// fallback exists so the bridge doesn't have to deal with `nil`
    /// when wiring up `Product.PurchaseOption.appAccountToken(_:)`.
    var purchaseAttributionToken: UUID {
        if let override = appAccountToken { return override }
        if let parsed = UUID(uuidString: anonymousId) { return parsed }
        return UUID()
    }

    /// Rotate anonymousId. Called after logOut to start a fresh anonymous
    /// session. Also clears the appAccountToken — the override belonged to
    /// the previous identity and reusing it on the next user would taint
    /// receipt attribution.
    func rotateAnonymousId() {
        let new = UUIDv7.next().uuidString.lowercased()
        defaults.set(new, forKey: Self.anonymousIdKey)
        anonymousId = new
        setAppAccountToken(nil)
    }
}
