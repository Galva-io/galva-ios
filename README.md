# Galva iOS SDK

The official iOS SDK for [Galva](https://galva.io) — retention infrastructure for subscription apps.

Subscription apps lose revenue at three predictable moments: **failed renewals**, **trials that don't convert**, and **subscribers who quietly churn**. Galva turns those moments into automated email, push, and in-app campaigns that win the revenue back — without you writing the retention pipeline yourself.

This SDK is the iOS client. Add it, identify your users, and Galva runs the playbook.

Open source · MIT-licensed. The Galva platform is hosted — [create a free account](https://galva.io) to get an API key.

| | |
|---|---|
| **Platforms** | iOS 15+, macOS 12+ |
| **Swift** | 5.9+ (Swift 6 strict concurrency) |
| **Distribution** | Swift Package Manager · prebuilt XCFramework |
| **Dependencies** | None — system frameworks only |

---

## Quick start

```swift
import Galva

@main struct MyApp: App {
    init() {
        Galva.configure(apiKey: "pk_live_xxxxxxxx")
    }
    var body: some Scene { WindowGroup { ContentView() } }
}

// Anywhere in your app:
AppUser.identify(userId: "user_42")
AppUser.set(.email, "peter@example.com")
AppEvents.track("AddHabitButtonTapped")
AppEvents.track("Purchase", attributes: ["sku": "pro_yearly", "price": 9.99])
```

That's the whole integration. Every public call returns synchronously — your UI thread never waits on Galva.

Grab your API key from your [Galva dashboard](https://galva.io).

---

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies** and paste:

```
https://github.com/nicegalva/galva-ios
```

Pick **Up to Next Major**.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/nicegalva/galva-ios", from: "1.0.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [.product(name: "Galva", package: "galva-ios")]
    )
]
```

### Prebuilt XCFramework

For teams that vendor binaries (no SPM resolution at build time, mixed-build pipelines):

1. Download `Galva.xcframework.zip` from the [latest release](https://github.com/nicegalva/galva-ios/releases).
2. Unzip and drag `Galva.xcframework` into your Xcode project.
3. Under your app target's **General → Frameworks, Libraries, and Embedded Content**, set the framework to **Embed & Sign**.

Each release also includes a ready-to-paste `.binaryTarget(url:checksum:)` snippet if you'd rather pin the binary via SPM.

CocoaPods is not supported.

---

## API

The SDK exposes four namespaces — each focused on one job.

### Identity — `AppUser`

```swift
AppUser.identify(userId: "user_42")
AppUser.identify(userId: "user_42", appAccountToken: UUID())   // StoreKit 2

// Built-in traits, compile-checked:
AppUser.set(.email, "peter@example.com")
AppUser.set(.fullName, "Peter Vu")
AppUser.set(.country, "VN")
AppUser.set(.timezone, "America/New_York")
AppUser.set(.languageCode, "en")
AppUser.set(.totalLifetimeValue, 199.99)

// Free-form custom traits:
AppUser.set("plan_tier", "pro")
AppUser.set("habit_count", 13)

// Synchronous read — safe from any thread:
if let userId = AppUser.identifiedUserId { … }

// Clears the user binding + rotates the anonymous ID:
AppUser.logOut()
```

For your own typed trait keys, conform to `AppUserAttribute`:

```swift
struct PlanTierTrait: AppUserAttribute {
    typealias Value = String
    var attributeName: String { "plan_tier" }
}

AppUser.set(PlanTierTrait(), "pro")
```

### Events — `AppEvents`

```swift
AppEvents.track("AddHabitButtonTapped")
AppEvents.track("Purchase", attributes: [
    "sku": "pro_yearly",
    "price": 9.99,
    "currency": "USD"
])
```

For events you emit a lot, define a typed struct so the call site is a one-liner and the compiler catches typos:

```swift
struct PurchaseEvent: AppEvents.Event {
    let sku: String
    let price: Double
    var eventName: String { "Purchase" }
    var attributes: EventAttributes? {
        ["sku": sku, "price": price]
    }
}

AppEvents.track(PurchaseEvent(sku: "pro_yearly", price: 9.99))
```

Event attribute values can be any `GalvaCompatibleValue` — `String`, `Int`, `Double`, `Bool`, `Date`, `URL`, `UUID`, `Decimal`, or any custom `Codable & Sendable` type.

### Communication — `Communication`

```swift
Communication.registerEmail("user@example.com")
Communication.registerPushToken(hexToken, platform: .apns)

// Per-workflow opt-in/out:
Communication.setPreference(
    channel: .email,
    disabled: false,
    categories: ["payment-recovery": true, "winback": false]
)

// Disable a channel entirely:
Communication.setPreference(channel: .pushNotification, disabled: true)
```

### Push tokens — `Galva`

```swift
// In your APNs registration callback (AppDelegate or SwiftUI lifecycle):
Galva.setDeviceToken(hexToken)
```

---

## Debugging integration

The SDK logs every action via Apple's `os.Logger`. Open **Console.app** on your Mac (or watch Xcode's debug console) and filter by subsystem:

```
subsystem:co.galva.sdk
```

Drill into a specific area:

| Category | What you'll see |
|---|---|
| `config` | configure lifecycle, logger installation |
| `identity` | every identify, track, logout |
| `queue` | batching, draining, retries with backoff |
| `storage` | SQLite + schema migrations |
| `uploader` | every HTTP request + response status |

Crank up verbosity during integration:

```swift
Galva.configure(apiKey: "...", logLevel: .debug)
```

Want Galva logs in your existing pipeline (Sentry breadcrumbs, Crashlytics, Datadog, a file)? Implement `GalvaLogger`:

```swift
struct CrashlyticsBreadcrumbs: GalvaLogger {
    func log(_ entry: Galva.LogEntry) {
        Crashlytics.crashlytics().log("[\(entry.category.rawValue)] \(entry.message)")
    }
}
Galva.setLogger(CrashlyticsBreadcrumbs())
```

The configured `logLevel` filter is still applied — your sink only sees entries that pass it.

---

## Performance

The SDK is built to be invisible to your app's perf budget:

- **API calls return in microseconds.** Every entry point hops to a background actor and returns; your UI thread never waits.
- **No main-thread work after `configure()`.** A one-time device snapshot is captured off-main during startup.
- **Bounded local queue.** Pending messages are capped at 10,000 (~10 MB worst case). Oldest are evicted FIFO when offline long enough to hit the cap — never unbounded growth.
- **Bounded retries.** Failed batches use exponential jitter capped at 60s — no busy-loop on outages.
- **No iCloud Backup pressure.** SQLite lives in `Application Support/Galva/` with the no-backup flag set; queued events don't bloat your users' iCloud Backups.

Every guarantee is locked in by contract tests in CI.

---

## Privacy

What the SDK collects:

- An anonymous device UUID, generated on first launch and stored locally
- Locale, timezone, OS version, app version (standard context fields)
- Anything you explicitly send via `identify`, `track`, or `set`

What the SDK does **not** do:

- Read the advertising identifier (IDFA) or request `App Tracking Transparency`
- Read contacts, photos, location, or any other system-protected data
- Swizzle UIKit, AppDelegate, or any other system class
- Make network calls before `configure()` is called

Your queued events live in `Application Support/Galva/` (excluded from iCloud Backup).

---

## Links

- **Galva platform** — [galva.io](https://galva.io)
- **Releases** — [GitHub Releases](https://github.com/nicegalva/galva-ios/releases)
- **Contributing** — [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE) for the full text.
