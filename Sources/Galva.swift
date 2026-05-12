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

// MARK: - Galva namespace

/// Top-level namespace for SDK configuration and global controls.
///
/// Call `Galva.configure(apiKey:)` once at app launch before any tracking
/// calls. Subsequent calls are ignored with a warning.
public enum Galva {

    // MARK: AutoTrack

    /// Auto-tracking categories. Pass an `OptionSet` to `configure(...)` to
    /// opt into automatic event collection for the listed categories.
    ///
    /// Default: `[.lifecycle, .transactions]`
    public struct AutoTrackCategory: OptionSet, Sendable {
        public var rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        /// Automatic app lifecycle events: `app_opened`, `app_backgrounded`,
        /// `app_foregrounded`. Driven by `UIApplication` notifications.
        public static let lifecycle:    AutoTrackCategory = .init(rawValue: 1 << 0)

        /// Forward StoreKit 2 transactions automatically as Galva events.
        public static let transactions: AutoTrackCategory = .init(rawValue: 1 << 1)
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
    ///         autoTrackCategories: [.lifecycle],
    ///         logLevel: .info
    ///     )
    public static func configure(
        apiKey: String,
        autoTrackCategories: AutoTrackCategory = [.lifecycle, .transactions],
        logLevel: LogLevel = .warning,
        logger: (any GalvaLogger)? = nil
    ) {
        Task { @GalvaActor in
            await SDKCore.shared.configure(
                apiKey: apiKey,
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

    /// Track an event with a string name and optional attributes.
    ///
    /// - Parameters:
    ///   - eventName: Wire name. Use a stable, snake_case or PascalCase
    ///     string from your taxonomy.
    ///   - attributes: Optional payload. Values must be `GalvaCompatibleValue`.
    ///
    /// Example:
    ///
    ///     AppEvents.track("AddHabitButtonTapped")
    ///     AppEvents.track("Purchase", attributes: [
    ///         "sku": "pro_yearly",
    ///         "price": 9.99,
    ///         "currency": "USD"
    ///     ])
    public static func track(_ eventName: String, attributes: EventAttributes? = nil) {
        let props = attributes?.mapValues { AnyJSONValue($0) }
        Task { @GalvaActor in
            await SDKCore.shared.track(event: eventName, properties: props)
        }
    }

    /// Track a strongly-typed `AppEvents.Event` value.
    public static func track<E: Event>(_ event: E) {
        track(event.eventName, attributes: event.attributes)
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

    /// Register an email address as a reachable endpoint for the current user.
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

/// In-app message streams.
///
/// > Note: Server-driven streaming lands in v2. APIs are present so call
/// > sites can be written today, but emit no values yet.
public enum InAppMessages {

    /// A server-driven in-app message addressed to the current user.
    ///
    /// Streamed via `InAppMessages.messages` (or per-type variants).
    /// Render the message however you like — typical UX is to load
    /// `contentUrl` in a sheet.
    public protocol Message: Sendable {
        /// Server-generated message id.
        var messageId: String { get }
        /// Originating workflow type (Trial Rescue, Payment Recovery, etc.).
        var messageType: MessageType { get }
        /// URL of the message content (HTML or remote view).
        var contentUrl: URL { get }
    }

    /// Workflow type that produced an in-app message.
    public enum MessageType: String, Sendable, CaseIterable {
        case trialRescue        = "trial_rescue"
        case subscriberRescue   = "subscriber_rescue"
        case paymentRecovery    = "payment_recovery"
        case winback            = "winback"
    }

    /// Stream of all in-app messages addressed to the current user.
    public static var messages: AsyncStream<any Message> {
        AsyncStream { _ in }
    }

    /// Stream of in-app messages filtered by one or more types.
    public static func messages(of types: MessageType...) -> AsyncStream<any Message> {
        AsyncStream { _ in }
    }
}
