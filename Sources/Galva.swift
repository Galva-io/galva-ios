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
//              Galva.configure(apiKey: "pk_your_app_id")
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
//  • Calls made while `configure` is still starting wait for it, then run in
//    call order. Identify and track calls made before `configure` are
//    dropped with a warning.
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

    /// Current SDK semantic version, matching the release tag and the
    /// `x-sdk-version` request header suffix.
    ///
    /// Useful for diagnostics screens and support reports:
    ///
    ///     let sdkVersion = Galva.sdkVersion
    public static let sdkVersion = SDKConstants.version
    
    // MARK: Environment
    
    /// Selects the Galva backend the SDK talks to. Different environments
    /// are fully isolated — production data never crosses into development
    /// and vice versa.
    ///
    /// Each App ID works only in the environment that issued it, and Galva
    /// rejects every request that pairs it with the other one. Leave this at
    /// `.production` unless you have an App ID issued for Galva's
    /// development environment.
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
    /// Default: `[.lifecycle, .appleSearchAds]`
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

        /// Resolve **Apple Search Ads** attribution once per install via the
        /// AdServices framework and attach the campaign fields to the user as
        /// `$gv_asa_*` traits (`$gv_asa_campaignId`, `$gv_asa_keywordId`,
        /// `$gv_asa_adGroupId`, …).
        ///
        /// On first launch the SDK reads `AAAttribution.attributionToken()`
        /// and resolves it against Apple's AdServices API, retrying a 404 per
        /// Apple's guidance (up to 3×, 5s apart) and a 5xx on the next launch.
        /// The resolved traits are persisted and re-attached to every
        /// `identify(...)`, so a later login keeps the attribution. Requires
        /// the AdServices framework (iOS 14.3+); a silent no-op where it isn't
        /// available (e.g. the Simulator). Honors `setOptOut(_:)`.
        public static let appleSearchAds: AutoTrackCategory = .init(rawValue: 1 << 1)
    }
    
    // MARK: LogLevel
    
    /// Minimum severity for log entries emitted by the SDK. Maps 1:1 onto
    /// the system `os.Logger` levels so output appears at the expected
    /// severity in Console.app and Xcode's debug console.
    ///
    ///     .debug   — extremely verbose; per-event payloads, every HTTP call
    ///     .info    — significant lifecycle: configure, identify, logOut, flush
    ///     .notice  — state changes worth knowing about
    ///     .warning — recoverable issues: retries, rate-limits, malformed config (default)
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
    ///
    /// The SDK may add categories in minor releases. It's a struct rather
    /// than an enum so that never breaks your build; if you switch on it,
    /// include a `default` case.
    public struct LogCategory: RawRepresentable, Sendable, Hashable, CaseIterable, CustomStringConvertible {

        /// The category's name in Console.app, e.g. `"queue"`.
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// SDK setup and configuration.
        public static let configuration = LogCategory(rawValue: "config")
        /// Identity store reads/writes and identify/logout lifecycle.
        public static let identity = LogCategory(rawValue: "identity")
        /// In-memory + on-disk message queue activity.
        public static let queue = LogCategory(rawValue: "queue")
        /// SQLite-backed message storage.
        public static let storage = LogCategory(rawValue: "storage")
        /// HTTP transport: every request, response status, and retry.
        public static let uploader = LogCategory(rawValue: "uploader")
        /// App-level lifecycle (cold start, background, foreground).
        public static let lifecycle = LogCategory(rawValue: "lifecycle")
        /// Integrations with other SDKs installed via
        /// `configure(…, integrations:)`, e.g. RevenueCat.
        public static let integration = LogCategory(rawValue: "integration")

        /// Every category this SDK version logs under.
        public static let allCases: [LogCategory] = [
            .configuration, .identity, .queue, .storage, .uploader, .lifecycle, .integration,
        ]

        public var description: String { rawValue }
    }
    
    // MARK: configure
    
    /// Configure the SDK. Call this once on app launch, ideally from
    /// `App.init()` or `application(_:didFinishLaunchingWithOptions:)`.
    ///
    /// Returns immediately and finishes in the background. Calls you make
    /// right after it, such as `AppUser.identify(userId:)`, wait for it and
    /// run in the order you made them. Subsequent calls are ignored with a
    /// warning log line.
    ///
    /// Example:
    ///
    ///     Galva.configure(
    ///         apiKey: "pk_your_app_id",
    ///         environment: .production,
    ///         autoTrackCategories: [.lifecycle],
    ///         logLevel: .info
    ///     )
    ///
    /// - Parameters:
    ///   - apiKey: Your App ID, from **Admin → Settings → Connect → Client
    ///     SDKs** in Galva. It starts with `pk_` and is safe to ship in your
    ///     app. The server resolves your app and environment from it.
    ///   - environment: Backend to talk to. Default is `.production`. Use
    ///     `.development` only with an App ID issued for Galva's development
    ///     environment, or `.custom(...)` for proxy setups.
    ///   - inAppMessages: How in-app messages reach the screen. Default:
    ///     `.automatic`, which presents each message as a sheet on your app's
    ///     active window. Pass `.manual` to present them yourself from
    ///     `InAppMessages.messages`.
    ///   - autoTrackCategories: Which categories of events the SDK should
    ///     collect automatically. Default: `[.lifecycle, .appleSearchAds]`.
    ///   - logLevel: Minimum severity to log. Default: `.warning`.
    ///   - logger: Optional custom logger. When `nil` (default), the SDK
    ///     writes to `os.Logger(subsystem: "co.galva.sdk", category: …)` —
    ///     open Console.app and filter `subsystem:co.galva.sdk` to see
    ///     every category in real time. Pass a custom logger to forward
    ///     SDK logs into your own pipeline (Sentry, Datadog, file
    ///     logger, etc.). The configured `logLevel` is still applied to
    ///     filter entries before they reach your logger.
    ///   - integrations: Connections to other SDKs in your app, from
    ///     integration packages — e.g. `[.revenueCat()]` from
    ///     `GalvaRevenueCat`. Installed in the background once Galva is
    ///     configured. Default: none.
    public static func configure(
        apiKey: String,
        environment: Environment = .production,
        inAppMessages: InAppMessages.Presentation = .automatic,
        autoTrackCategories: AutoTrackCategory = [.lifecycle, .appleSearchAds],
        logLevel: LogLevel = .warning,
        logger: (any GalvaLogger)? = nil,
        integrations: [Integration] = []
    ) {
        configure(
            apiKey: apiKey,
            environment: environment,
            inAppMessages: inAppMessages,
            autoTrackCategories: autoTrackCategories,
            logLevel: logLevel,
            logger: logger,
            integrations: integrations,
            wrapper: nil
        )
    }

    /// Configure the SDK on behalf of a first-party wrapper SDK (React Native,
    /// Flutter, …) that embeds this core, overriding the reported SDK identity.
    ///
    /// **Not public.** Wrappers compile in the same Swift module as the core
    /// (e.g. the React Native pod builds the core + bridge together), so they
    /// reach this seam without it widening the public native API. Native apps
    /// call ``configure(apiKey:environment:inAppMessages:autoTrackCategories:logLevel:logger:integrations:)``.
    ///
    /// `wrapper`'s name/version replace `ios`/`sdkVersion` in the
    /// `x-sdk-version` header, `context.library`, and the `sdk_version` event so
    /// wrapper traffic is distinguishable from native iOS. The identity is set
    /// synchronously, before any request is built. Pass `nil` to leave the
    /// native-core identity in place.
    static func configure(
        apiKey: String,
        environment: Environment = .production,
        inAppMessages: InAppMessages.Presentation = .automatic,
        autoTrackCategories: AutoTrackCategory = [.lifecycle, .appleSearchAds],
        logLevel: LogLevel = .warning,
        logger: (any GalvaLogger)? = nil,
        integrations: [Integration] = [],
        wrapper: SDKWrapper?
    ) {
        let core = SDKCore.shared
        guard claimConfiguration(of: core, reportingAs: wrapper) else { return }
        Task { @GalvaActor in
            await core.configure(
                apiKey: apiKey,
                environment: environment,
                autoTrack: autoTrackCategories,
                logLevel: logLevel,
                userLogger: logger,
                inAppMessages: inAppMessages,
                integrations: integrations
            )
        }
    }
    
    /// The synchronous half of `configure`: claim `core`'s configuration, so
    /// a repeat call is ignored (reported identity included) and calls made
    /// from here on wait for this configure, then set the reported identity
    /// before any request is built. `false` if `core` was already claimed.
    static func claimConfiguration(of core: SDKCore, reportingAs wrapper: SDKWrapper?) -> Bool {
        guard core.claimConfiguration() else { return false }
        SDKIdentity.wrapper = wrapper
        return true
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
        // Not held for an in-progress configure, so a logger set right after
        // `configure` also gets configure's own logs.
        Task { @GalvaActor in
            SDKCore.shared.installLogger(logger)
        }
    }
    
    /// Force an off-cycle reconciliation of the device's StoreKit
    /// transaction history with Galva's backend.
    ///
    /// Every time the app becomes active (cold start, return from the
    /// background, or a system overlay like Control Center closing) the
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
        SDKCore.shared.submit { await $0.reconcileTransactions() }
    }
    
    // MARK: Opt-out
    
    /// Globally disable / re-enable Galva's server-bound tracking.
    /// When opted out (`true`):
    ///   • `AppEvents.track`, `AppUser.identify`, and device-token /
    ///     endpoint registration calls become silent no-ops.
    ///   • Auto-tracked `session_start` events are suppressed.
    ///   • `Transaction.all` sweeps are skipped, so Galva doesn't
    ///     reconcile organic purchases for this device.
    ///   • The persisted on-disk event queue is purged on the
    ///     opted-in → opted-out transition so pre-existing events
    ///     don't leak after the user opts out.
    ///
    /// In-app message polling + rendering **continue** to work using
    /// the anonymous id. Opt-out blocks server-bound telemetry, not
    /// user-visible feature delivery.
    ///
    /// The flag is persisted in `UserDefaults` (`co.galva.optedOut`) so
    /// it survives app restarts. Defaults to `false` (tracking enabled)
    /// on first launch.
    ///
    /// Takes effect at once, even while `configure` is still starting:
    /// `Galva.isOptedOut` and every call made after this one see it. The
    /// queue purge runs in the background.
    public static func setOptOut(_ enabled: Bool) {
        SDKCore.shared.requestOptOut(enabled)
    }
    
    /// Current opt-out state. Synchronous read — safe to call from any
    /// thread, including a SwiftUI view body. Backed by a
    /// lock-protected mirror of the persisted `UserDefaults` flag, so
    /// the value is consistent with the most recent `setOptOut` call.
    public static var isOptedOut: Bool {
        SDKCore.shared.isOptedOut
    }
    
    /// Forward the APNs device token to Galva. Call this from your app
    /// delegate's
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` —
    /// pass the raw `Data` exactly as the OS hands it to you; the SDK
    /// hex-encodes it.
    ///
    /// The token is **device-scoped**: the SDK stores it and automatically
    /// keeps it associated with whoever is identified. You only call this once
    /// per launch — after `AppUser.identify(...)` or `AppUser.logOut()` the SDK
    /// re-registers the same token for the new user on its own. You never have
    /// to re-send it per user.
    ///
    /// Example:
    ///
    ///     func application(_ application: UIApplication,
    ///         didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    ///         Galva.applicationDidRegisterForRemoteNotificationsWithDeviceToken(deviceToken)
    ///     }
    public static func applicationDidRegisterForRemoteNotificationsWithDeviceToken(_ tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        SDKCore.shared.submit { await $0.registerDeviceToken(hex) }
    }

    /// Hand an incoming URL to Galva. SwiftUI apps call it from `onOpenURL` on
    /// their root view:
    ///
    ///     ContentView()
    ///         .onOpenURL { url in Galva.handleOpenURL(url) }
    ///
    /// UIKit apps forward from their App / Scene delegates — the
    /// `Galva.application(...)` / `Galva.scene(...)` mirrors in
    /// `Galva+OpenURL.swift` cover every entry point (cold + warm) and call
    /// this under the hood.
    ///
    /// - Returns: `true` if this is a Galva deep link (scheme begins with
    ///   `gv`) that the SDK has claimed, `false` otherwise. Galva only
    ///   handles its own `gv…` scheme — `http(s)` and your app's own custom
    ///   schemes return `false` and are untouched, so a UIKit
    ///   `application(_:open:)` can use the result to decide whether to route
    ///   the URL itself:
    ///
    ///     func application(_ app: UIApplication, open url: URL,
    ///                      options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    ///         if Galva.handleOpenURL(url) { return true }   // Galva took it
    ///         return myRouter.handle(url)                   // your own links
    ///     }
    ///
    /// The Galva-side handling itself is fire-and-forget (resolve + present
    /// happen asynchronously); the `Bool` is the synchronous "is this mine"
    /// decision based on the URL scheme.
    @discardableResult
    public static func handleOpenURL(_ url: URL) -> Bool {
        guard DeepLink.canHandle(url) else { return false }
        SDKCore.shared.submit { await $0.handleOpenURL(url) }
        return true
    }

    /// Forward a batch of opened URLs (e.g. the set delivered to a scene, or a
    /// cold-launch option). Each is run through `handleOpenURL(_:)`; Galva
    /// claims only its own `gv…` URLs and ignores the rest.
    ///
    /// Shared by the UIKit App / Scene delegate forwarders in
    /// `Galva+OpenURL.swift`. Platform-agnostic (takes plain `URL`s) so the
    /// extraction logic is host-testable without UIKit objects.
    ///
    /// - Returns: `true` if Galva claimed **at least one** of `urls`.
    @discardableResult
    static func handleOpenURLs(_ urls: [URL]) -> Bool {
        var claimed = false
        for url in urls where handleOpenURL(url) { claimed = true }
        return claimed
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
        SDKCore.shared.submit { await $0.track(event: eventName, properties: props) }
    }

    /// Track a strongly-typed `AppEvents.Event` value. Attributes flow through
    /// the typed `GalvaCompatibleValue` path — lossless, nothing is filtered.
    public static func track<E: Event>(_ event: E) {
        let props = event.attributes?.mapValues { AnyJSONValue($0) }
        SDKCore.shared.submit { await $0.track(event: event.eventName, properties: props) }
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
        public let attributeName = BuiltInTraitKey.email
    }

    /// Full-name trait. Server key: `$gv_fullName`.
    public struct FullName: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = BuiltInTraitKey.fullName
    }

    /// First-name trait. Server key: `$gv_firstName`.
    public struct FirstName: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = BuiltInTraitKey.firstName
    }

    /// Last-name trait. Server key: `$gv_lastName`.
    public struct LastName: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = BuiltInTraitKey.lastName
    }

    /// Country trait (ISO 3166 alpha-2). Server key: `$gv_country`.
    public struct Country: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = BuiltInTraitKey.country
    }

    /// Timezone trait (IANA name). Server key: `$gv_timezone`.
    /// Auto-attached from the device on every identify; set explicitly
    /// only to override (e.g. host app exposes its own picker).
    public struct Timezone: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = BuiltInTraitKey.timezone
    }

    /// Language code trait (BCP 47 tag). Server key: `$gv_languageCode`.
    /// Auto-attached from the device on every identify; set explicitly
    /// only to override.
    public struct LanguageCode: Sendable, AppUserAttribute {
        public typealias Value = String
        public let attributeName = BuiltInTraitKey.languageCode
    }

    /// Total lifetime value trait (currency, `Double`).
    /// Server key: `$gv_totalLifetimeValue`.
    public struct TotalLifetimeValue: Sendable, AppUserAttribute {
        public typealias Value = Double
        public let attributeName = BuiltInTraitKey.totalLifetimeValue
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

    /// The StoreKit 2 `appAccountToken` Galva attaches to purchases for the
    /// current identity. Returns the `appAccountToken` you passed to
    /// `identify(userId:appAccountToken:)` when set, otherwise the token Galva
    /// generates for you (the anonymous id as a UUID). It's the *same* value the
    /// SDK uses for its own purchases, so passing it into a purchase you start
    /// yourself reconciles that purchase to the same Galva account:
    ///
    ///     let token = AppUser.appAccountToken
    ///     let result = try await product.purchase(
    ///         options: token.map { [.appAccountToken($0)] } ?? []
    ///     )
    ///
    /// A synchronous snapshot, kept in sync with `configure`/`identify`/`logOut`
    /// and safe to read from any thread. `nil` only before `Galva.configure(...)`.
    public static var appAccountToken: UUID? {
        SDKCore.shared.cachedAppAccountToken
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
        SDKCore.shared.submit {
            await $0.identify(userId: userId, appAccountToken: appAccountToken, traits: nil)
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
        SDKCore.shared.submit { await $0.identify(userId: nil, appAccountToken: nil, traits: trait) }
    }

    /// Set an arbitrary user trait by string key. Use the typed `set(_:_:)`
    /// overload whenever possible — it catches typos at compile time.
    ///
    /// Example:
    ///
    ///     AppUser.set(attribute: "plan_tier", "pro")
    ///     AppUser.set(attribute: "habit_count", 13)
    public static func set<V: GalvaCompatibleValue>(attribute attributeName: String, _ value: V) {
        let trait = [attributeName: AnyJSONValue(value)]
        SDKCore.shared.submit { await $0.identify(userId: nil, appAccountToken: nil, traits: trait) }
    }

    /// Set one or more user traits from a loose `[String: Any]` dictionary
    /// — the lenient mirror of `AppEvents.track(_:attributes:)`.
    ///
    /// Use this when the values come from an untyped source (a JSON parse,
    /// `UserDefaults.dictionaryRepresentation()`, a host-side `[String: Any]`
    /// payload). Foundation-bridged values (`NSString`, `NSNumber`, `NSNull`,
    /// nested `NSDictionary` / `NSArray`) flow through cleanly so a host
    /// doesn't have to bridge each value to its Swift equivalent first — a
    /// failed bridge there is exactly the path that silently drops traits
    /// at the call site (e.g. an email read as `NSString` cast through a
    /// non-`@objc` protocol type ends up `nil`).
    ///
    /// Same rules as `AppEvents.track` for what survives the coercion:
    ///   • Kept: `String`, `Bool`, `Int`/`Int64`, `Double`/`Float`, `Decimal`,
    ///     `Date`, `URL`, `UUID`, any custom `Codable` `GalvaCompatibleValue`,
    ///     `NSNumber`/`NSString`/`NSNull`, and nested arrays/dictionaries of
    ///     those.
    ///   • Dropped: custom classes, closures, and other non-JSON values.
    ///
    /// Example:
    ///
    ///     // Reading what the host already has lying around as `[String: Any]`:
    ///     let stored = UserDefaults.standard.dictionaryRepresentation()
    ///     AppUser.set([
    ///         "$gv_email":    stored["email"]    ?? NSNull(),  // NSString → ok
    ///         "$gv_country":  stored["country"]  ?? NSNull(),
    ///         "plan_tier":    stored["plan"]     ?? NSNull(),
    ///     ])
    public static func set(_ attributes: [String: Any]) {
        let coerced = AnyJSONValue.coercing(dictionary: attributes)
        guard !coerced.isEmpty else { return }
        SDKCore.shared.submit { await $0.identify(userId: nil, appAccountToken: nil, traits: coerced) }
    }

    /// Log out the current user. Clears the identified user id and rotates
    /// the anonymous id so subsequent events are attributed to a fresh
    /// anonymous session.
    public static func logOut() {
        SDKCore.shared.submit { await $0.logOut() }
    }
}

// MARK: - InAppMessages

/// In-app message delivery.
///
/// Galva fetches pending in-app messages from active workflows every time
/// the app becomes active: the cold start, a return from the background, or
/// a system overlay like Control Center closing. Never on a timer. The
/// highest-priority message — resolved server-side from the workflow
/// waterfall — reaches the screen the way `Galva.configure(…, inAppMessages:)`
/// says:
///
/// - `.automatic` (default): the SDK presents it as a sheet on your app's
///   active window. There's nothing to write.
/// - `.manual`: the SDK presents nothing. Your app reads `messages` and
///   presents each one with `.inAppMessageSheet(_:)` (SwiftUI) or
///   `message.show()` (UIKit).
///
/// Either way, the SDK handles the page download and cache, identity, and the
/// native bridge (purchase prompt, dismissal, deep link, manage-subscription
/// URL).
public enum InAppMessages {

    /// Async stream of pending in-app messages addressed to the current
    /// identity. The SDK publishes the winning message after each
    /// foreground poll; multiple consumers may iterate concurrently.
    ///
    /// Every message is published here in both presentation modes. In
    /// `.manual` mode, this is where your app gets messages to present. A
    /// message published before your loop starts is held and handed to the
    /// first subscriber, so a loop that starts a moment after launch doesn't
    /// miss it. In `.automatic` mode the SDK already presents each message,
    /// so read the stream only to observe messages, not to present them
    /// again.
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
        SDKCore.shared.submit { await $0.inAppMessageManager?.checkForMessages() }
    }

    /// Errors `message.show(in:)` throws when a message can't be shown.
    ///
    /// Galva may add cases in minor releases. If you switch on this error,
    /// add an `@unknown default` case, so a new one only warns instead of
    /// breaking your build.
    public enum Error: Swift.Error, Sendable, Hashable {
        /// SDK has not been configured.
        case notConfigured
        /// The server no longer considers the message valid (workflow
        /// exited, message invalidated), or its id isn't one Galva issued.
        case messageNotFound
        /// WebView bundle for the resolved version isn't on disk and
        /// couldn't be downloaded.
        case bundleUnavailable
        /// No foreground window scene, or no view controller in it, to
        /// present the message on — or UIKit didn't finish presenting the
        /// sheet within a few seconds.
        case noPresentingViewController
        /// Galva's servers couldn't be reached, or returned an error, while
        /// resolving the message.
        case requestFailed
    }
}
