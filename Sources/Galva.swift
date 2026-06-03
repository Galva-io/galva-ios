//
//  Galva.swift
//  Galva
//
//  The public surface of the Galva iOS SDK.
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Quick start
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//
//      import Galva
//
//      @main struct MyApp: App {
//          init() {
//              Galva.configure(apiKey: "gv_pub_...")
//          }
//          var body: some Scene { WindowGroup { ContentView() } }
//      }
//
//      // …anywhere in your app
//      AppUser.identify(userId: "user_123")
//      AppUser.set(.email, "peter@example.com")
//      AppEvents.track("AddHabitButtonTapped")
//      AppEvents.track("Purchase", attributes: ["sku": "pro_yearly", "price": 9.99])
//
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Design contract
//  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  • All public APIs are fire-and-forget — they return synchronously and
//    enqueue work on `GalvaActor` behind the scenes. Safe to call from any
//    thread / actor.
//  • Events are persisted to disk (SQLite) before they leave the SDK, so they
//    survive crashes, kills, and network outages.
//  • Failed uploads retry with exponential backoff + jitter. 4xx errors
//    (other than 408/429) are treated as permanent and dropped after logging.
//  • The server resolves your appId and environment from `apiKey`. You don't
//    need to configure either explicitly.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Galva namespace

/// Top-level namespace for SDK configuration and global controls.
///
/// Call `Galva.configure(apiKey:)` once at app launch before any tracking
/// calls. Subsequent calls are ignored with a warning.
public enum Galva {

    // MARK: Environment

    /// Selects the Galva backend the SDK talks to. Different environments
    /// are fully isolated — production data never crosses into development
    /// and vice versa.
    ///
    /// Choose your environment per build target (e.g. `.development` for
    /// in-house TestFlight builds, `.production` for App Store releases).
    /// The same API key cannot be used across environments — `pk_live_*`
    /// keys are valid against `.production` only; `pk_test_*` against
    /// `.development`.
    public enum Environment: Sendable, Hashable {

        /// `api.galva.io` + `webview.galva.io`. App Store releases ship
        /// this. **Default** if you don't pass an environment.
        case production

        /// `api.galva.dev` + `webview.galva.dev`. Used for in-house dev /
        /// staging builds and local debugging.
        case development

        /// Custom backend — supply your own API + webview bundle CDN URLs.
        /// Reserved for on-prem and proxy setups; the standard SaaS path
        /// is `.production` / `.development`.
        ///
        /// - Parameters:
        ///   - apiBaseURL: Base URL the SDK appends RPC paths to
        ///     (`/sdk/initialize`, `/identities/batchCollect`, etc.).
        ///   - webviewBundleCDN: Origin the SDK downloads versioned
        ///     in-app message HTML bundles from. Each version is fetched
        ///     as `<webviewBundleCDN>/<version>.html`.
        case custom(apiBaseURL: URL, webviewBundleCDN: URL)

        /// Resolved API base URL for this environment.
        public var apiBaseURL: URL {
            switch self {
            case .production:   return SDKConstants.productionAPIBaseURL
            case .development:  return SDKConstants.developmentAPIBaseURL
            case .custom(let api, _): return api
            }
        }

        /// Resolved webview bundle CDN URL for this environment.
        public var webviewBundleCDN: URL {
            switch self {
            case .production:   return SDKConstants.productionWebviewBundleCDN
            case .development:  return SDKConstants.developmentWebviewBundleCDN
            case .custom(_, let cdn): return cdn
            }
        }
    }

    // MARK: AutoTrack

    /// Auto-tracking categories. Pass an `OptionSet` to `configure(...)` to
    /// opt into automatic event collection for the listed categories.
    ///
    /// Default: `[.lifecycle]`
    public struct AutoTrackCategory: OptionSet, Sendable {
        public var rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        /// Emit `session_start` events automatically. Driven by
        /// `UIApplication.didBecomeActive`:
        ///
        /// • Cold start always emits a `session_start`.
        /// • Foreground transition after 30+ minutes of background
        ///   inactivity emits a fresh `session_start`.
        /// • Returning to the foreground within 30 minutes does NOT
        ///   emit — the session continues.
        /// • There is no `session_end` event — duration is computed
        ///   server-side from successive `session_start` timestamps.
        ///
        /// Each event carries device-context properties:
        /// `device_locale`, `os_version`, `app_version`, `sdk_version`.
        /// `device_country` is derived server-side from the request IP.
        public static let lifecycle: AutoTrackCategory = .init(rawValue: 1 << 0)
    }

    // MARK: LogLevel

    /// Minimum severity for log entries emitted by the SDK. Maps 1:1 onto
    /// the system `os.Logger` levels so output appears at the expected
    /// severity in Console.app and Xcode's debug console.
    ///
    ///     .debug   — extremely verbose; per-event payloads, every HTTP call
    ///     .info    — significant lifecycle: configure, identify, logOut, flush
    ///     .notice  — state changes worth knowing about (default in dev)
    ///     .warning — recoverable issues: retries, rate-limits, malformed config
    ///     .error   — operation failed: permanent upload failure, decode failure
    ///     .fault   — invariant broken, data-loss risk
    ///     .off     — silence the SDK entirely
    public enum LogLevel: Int, Sendable, Comparable {
        case debug   = 0
        case info    = 1
        case notice  = 2
        case warning = 3
        case error   = 4
        case fault   = 5
        case off     = 99

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: LogCategory

    /// Logical area of the SDK that produced a log entry. Each category
    /// becomes a distinct `os.Logger`, which means you can filter to just
    /// one subsystem in Console.app:
    ///
    ///     subsystem:co.galva.sdk category:queue
    ///
    /// Custom `GalvaLogger` implementations receive the category on every
    /// `LogEntry` so they can route or annotate as they like.
    public enum LogCategory: String, Sendable, CaseIterable {
        /// SDK setup and configuration.
        case configuration = "config"
        /// Identity store reads/writes and identify/logout lifecycle.
        case identity
        /// In-memory + on-disk message queue activity.
        case queue
        /// SQLite-backed message storage.
        case storage
        /// HTTP transport: every request, response status, and retry.
        case uploader
        /// App-level lifecycle (cold start, background, foreground).
        case lifecycle
    }

    // MARK: configure

    /// Configure the SDK. Call this once on app launch, ideally from
    /// `App.init()` or `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Subsequent calls are ignored with a warning log line.
    ///
    /// - Parameters:
    ///   - apiKey: Your Galva publishable API key. The server resolves your
    ///     `appId` and environment from it.
    ///   - autoTrackCategories: Which categories of events the SDK should
    ///     collect automatically. Default: `[.lifecycle, .transactions]`.
    ///   - logLevel: Minimum severity to log. Default: `.warning`.
    ///   - logger: Optional custom logger. When `nil` (default), the SDK
    ///     writes to `os.Logger(subsystem: "co.galva.sdk", category: …)` —
    ///     open Console.app and filter `subsystem:co.galva.sdk` to see
    ///     every category in real time. Pass a custom logger to forward
    ///     SDK logs into your own pipeline (Sentry, Datadog, file
    ///     logger, etc.). The configured `logLevel` is still applied to
    ///     filter entries before they reach your logger.
    ///
    /// Example:
    ///
    ///     Galva.configure(
    ///         apiKey: "gv_pub_xxx",
    ///         environment: .production,
    ///         autoTrackCategories: [.lifecycle],
    ///         logLevel: .info
    ///     )
    ///
    /// - Parameters:
    ///   - apiKey: Your Galva publishable API key.
    ///   - environment: Backend to talk to. Default is `.production`. Use
    ///     `.development` for staging / TestFlight, or `.custom(...)` for
    ///     on-prem and proxy setups.
    ///   - autoTrackCategories: Auto-collected event categories.
    ///   - logLevel: Minimum severity to log.
    ///   - logger: Optional custom logger sink.
    public static func configure(
        apiKey: String,
        environment: Environment = .production,
        autoTrackCategories: AutoTrackCategory = [.lifecycle],
        logLevel: LogLevel = .warning,
        logger: (any GalvaLogger)? = nil
    ) {
        Task { @GalvaActor in
            await SDKCore.shared.configure(
                apiKey: apiKey,
                environment: environment,
                autoTrack: autoTrackCategories,
                logLevel: logLevel,
                userLogger: logger
            )
        }
    }

    /// Install a custom `GalvaLogger` at any point after `configure(...)`.
    /// The `logLevel` filter set at configure time is preserved — your
    /// logger only sees entries that pass it.
    ///
    /// Use this to wire Galva logs into your existing app pipeline:
    ///
    ///     struct CrashlyticsLogger: GalvaLogger {
    ///         func log(_ entry: Galva.LogEntry) {
    ///             Crashlytics.crashlytics().log("[\(entry.category.rawValue)] \(entry.message)")
    ///         }
    ///     }
    ///
    ///     Galva.setLogger(CrashlyticsLogger())
    public static func setLogger(_ logger: any GalvaLogger) {
        Task { @GalvaActor in
            SDKCore.shared.installLogger(logger)
        }
    }

    /// Force an off-cycle reconciliation of the device's StoreKit
    /// transaction history with Galva's backend.
    ///
    /// On every foreground (cold start + return from background) the
    /// SDK silently sweeps `Transaction.all` and posts
    /// `(originalTransactionId, userId)` mappings so Galva can resolve
    /// App Store notifications that arrive without an `appAccountToken`
    /// (organic purchases, native paywall, family-shared, restored).
    /// Call this method only when you need to short-circuit that
    /// foreground cadence — typical cases:
    ///
    /// 1. Right after your host-app billing observer acknowledges a
    ///    transaction inside the same session, and the next code path
    ///    expects Galva to have the mapping immediately (e.g. opening
    ///    an in-app message that reads entitlement).
    /// 2. Hooking into a "Restore Purchases" button in your support
    ///    flow so the user's historical entitlement aliases back onto
    ///    the new install / new device.
    ///
    /// Fire-and-forget: returns immediately. Idempotent — safe to call
    /// from anywhere, including duplicated taps. Errors are logged at
    /// `.info` / `.warning` and never surfaced to the caller.
    public static func reconcileTransactions() {
        Task { @GalvaActor in
            await SDKCore.shared.reconcileTransactions()
        }
    }

    // MARK: Opt-out

    /// Globally disable / re-enable Galva's server-bound tracking.
    /// When opted out (`true`):
    ///   • `AppEvents.track`, `AppUser.identify`, `Communication.*`
    ///     calls become silent no-ops.
    ///   • Auto-tracked `session_start` events are suppressed.
    ///   • `Transaction.all` sweeps are skipped, so Galva doesn't
    ///     reconcile organic purchases for this device.
    ///   • The persisted on-disk event queue is purged on the
    ///     opted-in → opted-out transition so pre-existing events
    ///     don't leak after the user opts out.
    ///
    /// In-app message polling + rendering **continue** to work using
    /// the anonymous id. Opt-out blocks server-bound telemetry, not
    /// user-visible feature delivery — give the user the option to
    /// disable in-app messages separately via
    /// `Communication.setPreference(channel: .inApp, disabled: true)`.
    ///
    /// The flag is persisted in `UserDefaults` (`co.galva.optedOut`) so
    /// it survives app restarts. Defaults to `false` (tracking enabled)
    /// on first launch.
    ///
    /// Fire-and-forget: returns immediately. Read the current value
    /// synchronously via `Galva.isOptedOut`.
    public static func setOptOut(_ enabled: Bool) {
        Task { @GalvaActor in
            await SDKCore.shared.setOptedOut(enabled)
        }
    }

    /// Current opt-out state. Synchronous read — safe to call from any
    /// thread, including a SwiftUI view body. Backed by a
    /// lock-protected mirror of the persisted `UserDefaults` flag, so
    /// the value is consistent with the most recent `setOptOut` call.
    public static var isOptedOut: Bool {
        SDKCore.shared.isOptedOut
    }

    /// Attach an APNs / FCM device token to outgoing messages. Required if
    /// you intend to register the device for push notifications via
    /// `Communication.registerPushToken(...)`.
    ///
    /// - Parameter token: The hex-encoded device token string.
    ///
    /// Example:
    ///
    ///     // In application(_:didRegisterForRemoteNotificationsWithDeviceToken:)
    ///     let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    ///     Galva.setDeviceToken(hex)
    public static func setDeviceToken(_ token: String) {
        Task { @GalvaActor in
            SDKCore.shared.setDeviceToken(token)
        }
    }
}

// MARK: - GalvaCompatibleValue

/// Marker protocol for value types accepted as event properties and user
/// traits. Conforming types are guaranteed to round-trip cleanly through
/// JSON.
///
/// Pre-conformed types: `Int`, `Int64`, `String`, `Double`, `Float`, `Bool`,
/// `Date`, `URL`, `UUID`, `Decimal`.
///
/// To make a custom value type compatible, conform to both `Sendable` and
/// `Codable`:
///
///     struct MyMetric: GalvaCompatibleValue { … }
public protocol GalvaCompatibleValue: Sendable, Codable {}
extension Int:     GalvaCompatibleValue {}
extension Int64:   GalvaCompatibleValue {}
extension String:  GalvaCompatibleValue {}
extension Double:  GalvaCompatibleValue {}
extension Float:   GalvaCompatibleValue {}
extension Bool:    GalvaCompatibleValue {}
extension Date:    GalvaCompatibleValue {}
extension URL:     GalvaCompatibleValue {}
extension UUID:    GalvaCompatibleValue {}
extension Decimal: GalvaCompatibleValue {}

/// Convenience alias for `[String: any GalvaCompatibleValue]`.
public typealias EventAttributes = [String: any GalvaCompatibleValue]

// MARK: - AppEvents

/// Event-tracking entry point.
///
/// All `track(...)` calls return immediately; the event is queued, persisted,
/// and uploaded asynchronously.
public enum AppEvents {

    /// Protocol for strongly-typed events. Conform a struct or enum to
    /// avoid stringly-typed `AppEvents.track("…")` call sites.
    ///
    /// Example:
    ///
    ///     struct PurchaseEvent: AppEvents.Event {
    ///         let sku: String
    ///         let price: Double
    ///         var eventName: String { "Purchase" }
    ///         var attributes: EventAttributes? {
    ///             ["sku": sku, "price": price]
    ///         }
    ///     }
    ///
    ///     AppEvents.track(PurchaseEvent(sku: "pro", price: 9.99))
    public protocol Event: Sendable {
        /// Wire name for the event, e.g. `"Purchase"`. Should match your
        /// taxonomy.
        var eventName: String { get }

        /// Optional properties attached to the event. `nil` for events
        /// with no payload.
        var attributes: EventAttributes? { get }
    }

    /// Track an event with a string name and an optional loose attribute bag.
    ///
    /// Attributes are `[String: Any]` for ergonomics — pass any dictionary
    /// (including one you already have, e.g. from JSON) without converting
    /// each value yourself. The SDK keeps everything JSON-compatible and
    /// **silently drops** anything that isn't:
    ///   • Kept: `String`, `Bool`, `Int`/`Int64`, `Double`/`Float`, `Decimal`,
    ///     `Date`, `URL`, `UUID`, any custom `Codable` `GalvaCompatibleValue`,
    ///     `NSNumber`/`NSString`/`NSNull`, and nested arrays/dictionaries of
    ///     those.
    ///   • Dropped: custom classes, closures, and other non-JSON values.
    ///
    /// For compile-time-checked attributes, define an `AppEvents.Event` and
    /// use the `track(_:)` overload instead.
    ///
    /// - Parameters:
    ///   - eventName: Wire name. Use a stable, snake_case or PascalCase
    ///     string from your taxonomy.
    ///   - attributes: Optional loose payload; incompatible values are filtered.
    ///
    /// Example:
    ///
    ///     AppEvents.track("AddHabitButtonTapped")
    ///     AppEvents.track("Purchase", attributes: [
    ///         "sku": "pro_yearly",
    ///         "price": 9.99,
    ///         "currency": "USD"
    ///     ])
    public static func track(_ eventName: String, attributes: [String: Any]? = nil) {
        let props = attributes.flatMap { dict -> [String: AnyJSONValue]? in
            let coerced = AnyJSONValue.coercing(dictionary: dict)
            return coerced.isEmpty ? nil : coerced
        }
        Task { @GalvaActor in
            await SDKCore.shared.track(event: eventName, properties: props)
        }
    }

    /// Track a strongly-typed `AppEvents.Event` value. Attributes flow through
    /// the typed `GalvaCompatibleValue` path — lossless, nothing is filtered.
    public static func track<E: Event>(_ event: E) {
        let props = event.attributes?.mapValues { AnyJSONValue($0) }
        Task { @GalvaActor in
            await SDKCore.shared.track(event: event.eventName, properties: props)
        }
    }
}

// MARK: - AppUser

/// Strongly-typed user trait keys. Conform a `struct` to this protocol to
/// define a typed setter that can be called as `AppUser.set(.myTrait, …)`.
///
/// Built-in trait keys: `.email`, `.fullName`, `.firstName`, `.lastName`,
/// `.country`, `.timezone`, `.languageCode`, `.totalLifetimeValue`. The
/// underlying types live in [`AppUserTraits`](x-source-tag://AppUserTraits)
/// — you rarely need to name them directly.
public protocol AppUserAttribute: Sendable {
    /// Type of the value this attribute accepts. Must be a Galva-compatible
    /// scalar.
    associatedtype Value: GalvaCompatibleValue

    /// Wire key on the server, e.g. `"$gv_email"` for built-ins or any
    /// custom key for your own traits.
    var attributeName: String { get }
}

// MARK: - AppUserTraits
//
// Sidecar namespace for the trait struct types. Developers reach these
// via dot-shorthand at the call site (`AppUser.set(.email, "…")`); the
// types are rarely typed by name, so they live here instead of inside
// `AppUser` to keep `AppUser.` autocomplete focused on methods.

/// Strongly-typed built-in user trait keys. Reach these via dot-shorthand:
///
///     AppUser.set(.email, "peter@example.com")
///     AppUser.set(.timezone, "America/New_York")
///
/// To define your own custom typed trait, conform a struct to
/// `AppUserAttribute` directly (you don't need to use this namespace).
public enum AppUserTraits {

    /// Email trait. Server key: `$gv_email`.
    public struct Email: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_email"
    }

    /// Full-name trait. Server key: `$gv_fullName`.
    public struct FullName: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_fullName"
    }

    /// First-name trait. Server key: `$gv_firstName`.
    public struct FirstName: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_firstName"
    }

    /// Last-name trait. Server key: `$gv_lastName`.
    public struct LastName: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_lastName"
    }

    /// Country trait (ISO 3166 alpha-2). Server key: `$gv_country`.
    public struct Country: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_country"
    }

    /// Timezone trait (IANA name). Server key: `$gv_timezone`.
    /// Auto-attached from the device on every identify; set explicitly
    /// only to override (e.g. host app exposes its own picker).
    public struct Timezone: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_timezone"
    }

    /// Language code trait (BCP 47 tag). Server key: `$gv_languageCode`.
    /// Auto-attached from the device on every identify; set explicitly
    /// only to override.
    public struct LanguageCode: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_languageCode"
    }

    /// Total lifetime value trait (currency, `Double`).
    /// Server key: `$gv_totalLifetimeValue`.
    public struct TotalLifetimeValue: Sendable, AppUserAttribute {
        public typealias Value = Double
        public let attributeName = "$gv_totalLifetimeValue"
    }
}

// MARK: - AppUserAttribute dot-shorthand
//
// These power `AppUser.set(.email, …)` etc. The static factories live on
// the protocol so they only appear in autocomplete after the `.` —
// they're invisible everywhere else.

public extension AppUserAttribute where Self == AppUserTraits.Email {
    static var email: AppUserTraits.Email { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.FullName {
    static var fullName: AppUserTraits.FullName { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.FirstName {
    static var firstName: AppUserTraits.FirstName { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.LastName {
    static var lastName: AppUserTraits.LastName { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.Country {
    static var country: AppUserTraits.Country { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.Timezone {
    static var timezone: AppUserTraits.Timezone { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.LanguageCode {
    static var languageCode: AppUserTraits.LanguageCode { .init() }
}

public extension AppUserAttribute where Self == AppUserTraits.TotalLifetimeValue {
    static var totalLifetimeValue: AppUserTraits.TotalLifetimeValue { .init() }
}

/// User identity and traits.
///
/// Galva tracks two kinds of identifiers:
/// 1. **Anonymous ID** — generated on first launch, persisted across sessions
///    until `logOut()` rotates it. Always present.
/// 2. **End-user ID** — your app's user id, set via `identify(userId:)`.
///    `nil` until you call `identify`.
public enum AppUser {

    /// Currently-identified end-user id. Returns `nil` if no user has been
    /// identified, or if `logOut()` was called.
    ///
    /// This is a synchronous snapshot, kept in sync with `identify`/`logOut`.
    /// Safe to read from any thread.
    public static var identifiedUserId: String? {
        SDKCore.shared.cachedEndUserId
    }

    /// Identify the current end user. Subsequent events are attributed to
    /// this user id until `logOut()` is called.
    ///
    /// - Parameters:
    ///   - userId: Your app's stable identifier for the user.
    ///   - appAccountToken: Optional StoreKit 2 `appAccountToken` (UUID) for
    ///     linking subscription purchases to this user.
    ///
    /// Example:
    ///
    ///     AppUser.identify(userId: "user_42")
    public static func identify(userId: String, appAccountToken: UUID? = nil) {
        Task { @GalvaActor in
            await SDKCore.shared.identify(
                userId: userId,
                appAccountToken: appAccountToken,
                traits: nil
            )
        }
    }

    /// Set a typed user trait.
    ///
    /// Example:
    ///
    ///     AppUser.set(.email, "peter@example.com")
    ///     AppUser.set(.firstName, "Peter")
    public static func set<A: AppUserAttribute>(_ attribute: A, _ value: A.Value) {
        let trait = [attribute.attributeName: AnyJSONValue(value)]
        Task { @GalvaActor in
            await SDKCore.shared.identify(userId: nil, appAccountToken: nil, traits: trait)
        }
    }

    /// Set an arbitrary user trait by string key. Use the typed `set(_:_:)`
    /// overload whenever possible — it catches typos at compile time.
    ///
    /// Example:
    ///
    ///     AppUser.set("plan_tier", "pro")
    ///     AppUser.set("habit_count", 13)
    public static func set<V: GalvaCompatibleValue>(_ attributeName: String, _ value: V) {
        let trait = [attributeName: AnyJSONValue(value)]
        Task { @GalvaActor in
            await SDKCore.shared.identify(userId: nil, appAccountToken: nil, traits: trait)
        }
    }

    /// Log out the current user. Clears the identified user id and rotates
    /// the anonymous id so subsequent events are attributed to a fresh
    /// anonymous session.
    public static func logOut() {
        Task { @GalvaActor in
            await SDKCore.shared.logOut()
        }
    }
}

// MARK: - Communication

/// Register / unregister communication endpoints (email, push) and set
/// per-workflow communication preferences.
///
/// Endpoints are how Galva reaches the user outside the app — email and
/// push notifications. Preferences control which workflows (Trial Rescue,
/// Payment Recovery, Winback…) are allowed to use each channel.
public enum Communication {

    // MARK: Public enums

    /// Push provider for a device token.
    public enum PushPlatform: String, Sendable, Hashable {
        /// Apple Push Notification service (default on Apple platforms).
        case apns
        /// Firebase Cloud Messaging.
        case fcm
    }

    /// Communication channel a preference applies to.
    public enum Channel: String, Sendable, Hashable {
        case email
        case pushNotification
        case inApp
    }

    /// Validate an email address against Galva's basic ingestion rules:
    /// exactly one `@` with non-empty local and domain parts, a dotted domain,
    /// no whitespace, and a basic RFC 5322 character set.
    ///
    /// `registerEmail(_:)` already validates internally and silently skips
    /// invalid addresses so they never reach the server. Call this first when
    /// you want to surface a validation error in your own UI:
    ///
    ///     guard Communication.isValidEmail(input) else {
    ///         showError("Please enter a valid email address")
    ///         return
    ///     }
    ///     Communication.registerEmail(input)
    public static func isValidEmail(_ email: String) -> Bool {
        EmailValidator.isValid(email)
    }

    /// Register an email address as a reachable endpoint for the current user.
    ///
    /// The address is validated client-side first (see `isValidEmail(_:)`);
    /// an invalid address is **not** sent to the server — it's dropped with a
    /// warning log. Validate up front with `isValidEmail(_:)` if you need to
    /// tell the user.
    ///
    /// Example:
    ///
    ///     Communication.registerEmail("peter@example.com")
    public static func registerEmail(_ email: String) {
        Task { @GalvaActor in
            await SDKCore.shared.createEndpoint(.email(email))
        }
    }

    /// Remove a previously-registered email endpoint.
    public static func unregisterEmail(_ email: String) {
        Task { @GalvaActor in
            await SDKCore.shared.deleteEndpoint(.email(email))
        }
    }

    /// Register an APNs (or FCM) device token as a push-notification endpoint.
    ///
    /// - Parameters:
    ///   - token: Hex-encoded device token.
    ///   - platform: `.apns` (default) or `.fcm`.
    ///
    /// Example:
    ///
    ///     Communication.registerPushToken(hexToken)              // .apns
    ///     Communication.registerPushToken(fcmToken, platform: .fcm)
    public static func registerPushToken(_ token: String, platform: PushPlatform = .apns) {
        Task { @GalvaActor in
            await SDKCore.shared.createEndpoint(.pushNotification(platform: platform.wireValue, token: token))
        }
    }

    /// Remove a previously-registered push-notification endpoint.
    public static func unregisterPushToken(_ token: String, platform: PushPlatform = .apns) {
        Task { @GalvaActor in
            await SDKCore.shared.deleteEndpoint(.pushNotification(platform: platform.wireValue, token: token))
        }
    }

    /// Update communication preferences for a channel.
    ///
    /// - Parameters:
    ///   - channel: Channel to update (`.email`, `.pushNotification`, `.inApp`).
    ///   - disabled: If `true`, disables the channel entirely.
    ///   - categories: Per-workflow toggles (workflow type → enabled). Common
    ///     keys: `"payment-recovery"`, `"prechurn-save"`, `"winback"`.
    ///
    /// Example — opt the user out of payment recovery emails:
    ///
    ///     Communication.setPreference(
    ///         channel: .email,
    ///         categories: ["payment-recovery": false]
    ///     )
    public static func setPreference(
        channel: Channel,
        disabled: Bool? = nil,
        categories: [String: Bool]? = nil
    ) {
        Task { @GalvaActor in
            await SDKCore.shared.setPreference(channel: channel.wireValue, disabled: disabled, categories: categories)
        }
    }
}


// MARK: - InAppMessages

/// In-app message delivery.
///
/// Galva fetches pending in-app messages from active workflows on every
/// app foreground event (cold start + return from background). The
/// highest-priority message — resolved server-side from the workflow
/// waterfall — is published on the `messages` stream.
///
/// To render a message, await it on the stream and call `show(in:)` on
/// it. The SDK presents a sheet hosting a `WKWebView` that loads the
/// versioned HTML bundle. Bundle download, on-disk cache, identity, and
/// the native bridge (purchase prompt, dismissal, deep link, manage-
/// subscription URL) are all handled internally.
///
/// Example:
///
///     Task { @MainActor in
///         for await message in InAppMessages.messages {
///             guard let scene = UIApplication.shared
///                 .connectedScenes
///                 .first(where: { $0.activationState == .foregroundActive })
///                 as? UIWindowScene
///             else { continue }
///             try? await message.show(in: scene)
///         }
///     }
///
/// To opt out: simply don't consume `messages`. The SDK still polls (so
/// suppression analytics stay accurate) but nothing renders.
public enum InAppMessages {

    /// Async stream of pending in-app messages addressed to the current
    /// identity. The SDK publishes the winning message after each
    /// foreground poll; multiple consumers may iterate concurrently.
    ///
    /// `@MainActor`: the stream is main-actor-isolated, so when you iterate
    /// it from a MainActor context — a SwiftUI `.task { … }` or
    /// `Task { @MainActor in … }` — each message is delivered on the main
    /// thread and you can drive UI (present a sheet, call `show(in:)`) in the
    /// loop body without a manual hop.
    @MainActor
    public static var messages: AsyncStream<InAppMessages.Message> {
        SDKCore.shared.inAppMessageStream.makeStream()
    }

    /// Manually trigger a poll for pending messages. Normally driven by
    /// the foreground lifecycle — use this when you want to refresh
    /// outside the standard cold-start / return-to-foreground cadence
    /// (e.g. after the user completes an in-app action that should
    /// retrigger a workflow attempt).
    public static func checkForMessages() {
        Task { @GalvaActor in
            await SDKCore.shared.inAppMessageManager?.checkForMessages()
        }
    }

    /// Errors surfaced from the in-app messaging pipeline.
    public enum Error: Swift.Error, Sendable, Hashable {
        /// SDK has not been configured.
        case notConfigured
        /// `show(_:in:)` received a message id the server no longer
        /// considers valid (workflow exited, message invalidated).
        case messageNotFound
        /// WebView bundle for the resolved version isn't on disk and
        /// couldn't be downloaded.
        case bundleUnavailable
        /// Bundle requested a bridge protocol the installed SDK doesn't
        /// support — update the SDK to render this message.
        case bridgeProtocolMismatch
    }
}
