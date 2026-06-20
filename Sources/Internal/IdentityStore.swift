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
    private static let deviceTokenKey       = "co.galva.deviceToken"
    private static let asaResolvedKey       = "co.galva.asaResolved"
    private static let asaTraitsKey         = "co.galva.asaTraits"

    private(set) var anonymousId: String
    private(set) var endUserId: String?

    /// APNs push token (hex) for THIS device. Device-scoped, not user-scoped:
    /// set once when the OS hands us a token and reused for whoever is
    /// identified — so it is deliberately **not** cleared on `logOut()` /
    /// `rotateAnonymousId()`. Persisted so it survives launches and is
    /// available to re-register against a new identity before the next
    /// OS token callback arrives.
    private(set) var deviceToken: String?

    /// Developer-supplied StoreKit `appAccountToken` override. Set via
    /// `AppUser.identify(userId:appAccountToken:)`. `nil` when the host
    /// app hasn't supplied one — the SDK then falls back to deriving the
    /// attribution token from `anonymousId` (see
    /// `purchaseAttributionToken` below).
    private(set) var appAccountToken: UUID?

    /// Whether Apple Search Ads attribution has been resolved — a 200 from
    /// AdServices, whether or not the install was attributed. Device-scoped
    /// and one-shot per install: persisted, **not** cleared on `logOut()` /
    /// `rotateAnonymousId()`, so the SDK never re-fetches.
    private(set) var appleSearchAdsResolved: Bool

    /// Resolved `$gv_asa_*` attribution traits (empty when the install wasn't
    /// attributed). Re-attached to every identify so a later login carries the
    /// install's Apple Search Ads attribution.
    private(set) var appleSearchAdsTraits: [String: AnyJSONValue]

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
        deviceToken = defaults.string(forKey: Self.deviceTokenKey)

        appleSearchAdsResolved = defaults.bool(forKey: Self.asaResolvedKey)
        if let data = defaults.data(forKey: Self.asaTraitsKey),
           let decoded = try? JSONDecoder().decode([String: AnyJSONValue].self, from: data) {
            appleSearchAdsTraits = decoded
        } else {
            appleSearchAdsTraits = [:]
        }
    }

    /// Persist the Apple Search Ads resolution outcome. Device-scoped — like
    /// `deviceToken`, deliberately survives `logOut()` so we never re-fetch
    /// install-level attribution.
    func setAppleSearchAds(resolved: Bool, traits: [String: AnyJSONValue]) {
        appleSearchAdsResolved = resolved
        appleSearchAdsTraits = traits
        defaults.set(resolved, forKey: Self.asaResolvedKey)
        if let data = try? JSONEncoder().encode(traits) {
            defaults.set(data, forKey: Self.asaTraitsKey)
        }
    }

    /// Persist (or clear) the device's push token. Device-scoped — survives
    /// `logOut()` so the next user keeps the same token.
    func setDeviceToken(_ token: String?) {
        deviceToken = token
        if let token {
            defaults.set(token, forKey: Self.deviceTokenKey)
        } else {
            defaults.removeObject(forKey: Self.deviceTokenKey)
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
    /// receipt attribution. The `deviceToken` is intentionally **kept** — it
    /// belongs to the device, so the next (anonymous) user inherits it.
    func rotateAnonymousId() {
        let new = UUIDv7.next().uuidString.lowercased()
        defaults.set(new, forKey: Self.anonymousIdKey)
        anonymousId = new
        setAppAccountToken(nil)
    }
}
