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

    /// Minimum severity for log entries emitted by the SDK. Higher values
    /// suppress more output.
    ///
    ///     .debug    — extremely verbose; per-event payloads
    ///     .info     — flushes, identity changes, workflow attempts
    ///     .notice   — significant events (default in production)
    ///     .warning  — retries, rate-limits, recoverable issues
    ///     .error    — failed flushes, decode failures
    ///     .critical — invariant broken, data-loss risk
    ///     .off      — silence the SDK entirely
    public enum LogLevel: Int, Sendable, Comparable {
        case debug    = 0
        case info     = 1
        case notice   = 2
        case warning  = 3
        case error    = 4
        case critical = 5
        case off      = 99

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
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
        logLevel: LogLevel = .warning
    ) {
        Task { @GalvaActor in
            await SDKCore.shared.configure(
                apiKey: apiKey,
                autoTrack: autoTrackCategories,
                logLevel: logLevel
            )
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

// MARK: - AppEvent

/// Protocol for strongly-typed events. Implement this on a struct/enum to
/// avoid stringly-typed `AppEvents.track("...")` call sites.
///
/// Example:
///
///     struct PurchaseEvent: AppEvent {
///         let sku: String
///         let price: Double
///         var eventName: String { "Purchase" }
///         var attributes: EventAttributes? {
///             ["sku": sku, "price": price]
///         }
///     }
///
///     AppEvents.track(PurchaseEvent(sku: "pro", price: 9.99))
public protocol AppEvent: Sendable {
    /// Wire name for the event, e.g. `"Purchase"`. Should match your
    /// taxonomy.
    var eventName: String { get }

    /// Optional properties attached to the event. `nil` for events with no
    /// payload.
    var attributes: EventAttributes? { get }
}

// MARK: - AppEvents

/// Event-tracking entry point.
///
/// All `track(...)` calls return immediately; the event is queued, persisted,
/// and uploaded asynchronously.
public enum AppEvents {

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

    /// Track a strongly-typed `AppEvent` value.
    public static func track<E: AppEvent>(_ event: E) {
        track(event.eventName, attributes: event.attributes)
    }
}

// MARK: - AppUser

/// Strongly-typed user trait keys. Conform a `struct` to this protocol to
/// define a typed setter that can be called as `AppUser.set(.myTrait, …)`.
///
/// Built-in default attributes: `.email`, `.fullName`, `.firstName`,
/// `.lastName`, `.country`.
public protocol AppUserAttribute: Sendable {
    /// Type of the value this attribute accepts. Must be a Galva-compatible
    /// scalar.
    associatedtype Value: GalvaCompatibleValue

    /// Wire key on the server, e.g. `"$gv_email"` for built-ins or any
    /// custom key for your own traits.
    var attributeName: String { get }
}

public extension AppUserAttribute where Self == AppUser.EmailAttribute {
    /// Built-in email trait. Maps to server key `$gv_email`.
    static var email: AppUser.EmailAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.FullNameAttribute {
    /// Built-in full-name trait. Maps to server key `$gv_fullName`.
    static var fullName: AppUser.FullNameAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.FirstNameAttribute {
    /// Built-in first-name trait. Maps to server key `$gv_firstName`.
    static var firstName: AppUser.FirstNameAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.LastNameAttribute {
    /// Built-in last-name trait. Maps to server key `$gv_lastName`.
    static var lastName: AppUser.LastNameAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.CountryAttribute {
    /// Built-in country trait. Maps to server key `$gv_country`. Use ISO 3166
    /// alpha-2 codes (e.g. `"US"`, `"VN"`).
    static var country: AppUser.CountryAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.TimezoneAttribute {
    /// Built-in timezone trait. Maps to server key `$gv_timezone`. Use IANA
    /// names (e.g. `"America/New_York"`).
    ///
    /// The SDK auto-attaches the device's current timezone on every identify
    /// call (anonymous and identified). Set this explicitly only to override.
    static var timezone: AppUser.TimezoneAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.LanguageCodeAttribute {
    /// Built-in language code trait. Maps to server key `$gv_languageCode`.
    /// BCP 47 language tag (e.g. `"en"`, `"en-US"`).
    ///
    /// The SDK auto-attaches the device's current language code on every
    /// identify call (anonymous and identified). Set this explicitly only
    /// to override (e.g. host app has an in-app language picker).
    static var languageCode: AppUser.LanguageCodeAttribute { .init() }
}

public extension AppUserAttribute where Self == AppUser.TotalLifetimeValueAttribute {
    /// Built-in total lifetime value trait. Maps to server key
    /// `$gv_totalLifetimeValue`. Value is a currency amount as a `Double`.
    static var totalLifetimeValue: AppUser.TotalLifetimeValueAttribute { .init() }
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

    // MARK: Default trait attribute types (canonical `$gv_*` server keys)

    /// Email trait attribute. Server key: `$gv_email`.
    public struct EmailAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_email"
    }

    /// Full-name trait attribute. Server key: `$gv_fullName`.
    public struct FullNameAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_fullName"
    }

    /// First-name trait attribute. Server key: `$gv_firstName`.
    public struct FirstNameAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_firstName"
    }

    /// Last-name trait attribute. Server key: `$gv_lastName`.
    public struct LastNameAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_lastName"
    }

    /// Country trait attribute (ISO 3166 alpha-2). Server key: `$gv_country`.
    public struct CountryAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_country"
    }

    /// Timezone trait attribute (IANA name). Server key: `$gv_timezone`.
    public struct TimezoneAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_timezone"
    }

    /// Language code trait attribute (BCP 47 tag).
    /// Server key: `$gv_languageCode`.
    public struct LanguageCodeAttribute: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = "$gv_languageCode"
    }

    /// Total lifetime value trait attribute (currency amount, `Double`).
    /// Server key: `$gv_totalLifetimeValue`.
    public struct TotalLifetimeValueAttribute: Sendable, AppUserAttribute {
        public typealias Value = Double
        public let attributeName = "$gv_totalLifetimeValue"
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

// MARK: - InAppMessage

/// A server-driven in-app message addressed to the current user.
///
/// Streamed via `InAppMessages.messages` (or per-type variants). Render the
/// message however you like — typical UX is to load `contentUrl` in a sheet.
///
/// > Note: In-app messages are a planned v2 feature. The current stream
/// > returns no values.
public protocol InAppMessage: Sendable {
    /// Server-generated message id.
    var messageId: String { get }
    /// Originating workflow type (Trial Rescue, Payment Recovery, etc.).
    var messageType: InAppMessages.MessageType { get }
    /// URL of the message content (HTML or remote view).
    var contentUrl: URL { get }
}

/// In-app message streams.
///
/// > Note: Server-driven streaming lands in v2. APIs are present so call
/// > sites can be written today, but emit no values yet.
public enum InAppMessages {

    /// Workflow type that produced an in-app message.
    public enum MessageType: String, Sendable, CaseIterable {
        case trialRescue        = "trial_rescue"
        case subscriberRescue   = "subscriber_rescue"
        case paymentRecovery    = "payment_recovery"
        case winback            = "winback"
    }

    /// Stream of all in-app messages addressed to the current user.
    public static var messages: AsyncStream<InAppMessage> {
        AsyncStream { _ in }
    }

    /// Stream of in-app messages filtered by one or more types.
    public static func messages(of types: MessageType...) -> AsyncStream<InAppMessage> {
        AsyncStream { _ in }
    }
}
