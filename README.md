# Galva iOS SDK

The official iOS SDK for [Galva](https://galva.io) — retention infrastructure for subscription apps.

Subscription apps lose revenue at three predictable moments: **failed renewals**, **trials that don't convert**, and **subscribers who quietly churn**. Galva turns those moments into automated email, push, and in-app campaigns that win the revenue back — so you don't have to build the retention pipeline yourself.

This SDK is the iOS client. Add it, identify your users, drop in one line to render in-app messages, and Galva runs the playbook.

Open source · MIT-licensed. The Galva platform is hosted — [create a free account](https://galva.io) to get an API key.

| | |
|---|---|
| **Runtime** | iOS 15+ · macOS 12+ |
| **Build** | Xcode 26+ (the StoreKit offer path uses an iOS 26 SDK API that's back-deployed to iOS 15 at runtime) |
| **Distribution** | Swift Package Manager · prebuilt XCFramework |
| **Dependencies** | None — system frameworks only |
| **Threading** | Every public call is fire-and-forget and safe from any thread |

---

## How it works

```
Your app                    Galva SDK                         Galva backend
────────                    ─────────                         ─────────────
configure(apiKey:)  ───▶    registers, polls on foreground ──▶ resolves workflows
identify / track    ───▶    persists to SQLite, batches    ──▶ ingests, attributes
                            ◀── delivers pending message ────  workflow waterfall
.autoDisplayInAppMessages() ─▶ renders the message sheet
```

You send identity + events. Galva decides *who* needs a nudge and *when*, and hands your app a message to render. Email and push are delivered server-side; in-app messages render through this SDK. **The only UI you add is one modifier** — everything else (bundle download, caching, the WebView, the native bridge, StoreKit purchase prompts) is internal.

---

## Quick start

Three steps, ~5 minutes.

**1. Add the package** — in Xcode: **File → Add Package Dependencies…**

```
https://github.com/Galva-io/galva-ios
```

**2. Configure once at launch**, then identify your user:

```swift
import Galva

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .galvaConfigure(apiKey: "pk_live_xxxxxxxx")  // configure + deep links
                .autoDisplayInAppMessages()                  // 3. render retention messages
        }
    }
}
```

`.galvaConfigure(...)` configures the SDK and **auto-wires deep links** (it attaches `onOpenURL` for you — no manual forwarding). Prefer calling `Galva.configure(...)` from `App.init()` / your `AppDelegate` instead? That works too; just forward URL opens with `Galva.handleOpenURL(_:)` yourself.

**Anywhere in your app**, tell Galva who the user is and what they do:

```swift
AppUser.identify(userId: "user_42")
AppUser.set(.email, "peter@example.com")

AppEvents.track("AddHabitButtonTapped")
AppEvents.track("Purchase", attributes: ["sku": "pro_yearly", "price": 9.99])
```

That's the whole integration. Every call returns synchronously — your UI thread never waits on Galva. Grab your API key from the [Galva dashboard](https://galva.io).

---

## Install

### Swift Package Manager

In Xcode: **File → Add Package Dependencies** and paste the repo URL, then pick **Up to Next Major Version**:

```
https://github.com/Galva-io/galva-ios
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Galva-io/galva-ios", from: "1.0.0"),
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

1. Download `Galva.xcframework.zip` from the [latest release](https://github.com/Galva-io/galva-ios/releases).
2. Unzip and drag `Galva.xcframework` into your project.
3. Under your app target's **General → Frameworks, Libraries, and Embedded Content**, set it to **Embed & Sign**.

Each release also ships a ready-to-paste `.binaryTarget(url:checksum:)` snippet if you'd rather pin the binary via SPM. CocoaPods is not supported.

> **Build requirement:** Galva builds with **Xcode 26+**. The StoreKit promotional-offer path uses `Product.PurchaseOption.promotionalOffer(_:compactJWS:)`, an iOS 26 SDK symbol that is back-deployed (`@backDeployed`) to **run on iOS 15+** — so your app's deployment target stays at iOS 15, but the SDK must be *compiled* with the iOS 26 SDK.

---

## Configure

**SwiftUI** — apply `.galvaConfigure(...)` to your root view (configures the SDK once and auto-attaches deep-link forwarding):

```swift
ContentView()
    .galvaConfigure(
        apiKey: "pk_live_xxxxxxxx",
        environment: .production,
        autoTrackCategories: [.lifecycle],
        logLevel: .warning
    )
```

**UIKit / manual** — call `Galva.configure(apiKey:)` **once**, as early as possible (`application(_:didFinishLaunchingWithOptions:)`), and forward deep links with `Galva.handleOpenURL(_:)`. Subsequent `configure` calls are ignored with a warning.

```swift
Galva.configure(
    apiKey: "pk_live_xxxxxxxx",
    environment: .production,
    autoTrackCategories: [.lifecycle],
    logLevel: .warning
)
```

Both take the same parameters (`.galvaConfigure` mirrors `configure`):

| Parameter | Default | Notes |
|---|---|---|
| `apiKey` | — | Your publishable key. The server resolves your app + environment from it. |
| `environment` | `.production` | `.production` (`pk_live_*`), `.development` (`pk_test_*`), or `.custom(apiBaseURL:webviewBundleCDN:)`. Environments are fully isolated. |
| `autoTrackCategories` | `[.lifecycle]` | `.lifecycle` auto-emits `session_start` (cold start + foreground after 30 min idle). Pass `[]` to disable. |
| `logLevel` | `.warning` | `.debug` `.info` `.notice` `.warning` `.error` `.fault` `.off`. Use `.debug` while integrating. |
| `logger` | `nil` (os.Logger) | Optional custom `GalvaLogger` sink — see [Debugging](#debugging). |

**Environment per build configuration** is the common pattern:

```swift
#if DEBUG
Galva.configure(apiKey: "pk_test_xxx", environment: .development, logLevel: .debug)
#else
Galva.configure(apiKey: "pk_live_xxx", environment: .production)
#endif
```

---

## Identify your users — `AppUser`

Attribution starts the moment you call `identify`. Before that, events attach to an anonymous device ID that's generated on first launch; `identify` links that anonymous history to your user.

```swift
AppUser.identify(userId: "user_42")
AppUser.identify(userId: "user_42", appAccountToken: someUUID)   // link StoreKit purchases

// Built-in traits — compile-checked via dot-shorthand:
AppUser.set(.email, "peter@example.com")
AppUser.set(.fullName, "Peter Vu")
AppUser.set(.country, "VN")            // ISO 3166 alpha-2
AppUser.set(.timezone, "America/New_York")
AppUser.set(.languageCode, "en")
AppUser.set(.totalLifetimeValue, 199.99)

// Free-form custom traits:
AppUser.set("plan_tier", "pro")
AppUser.set("habit_count", 13)

// Synchronous read — safe from any thread, incl. a SwiftUI body:
if let userId = AppUser.identifiedUserId { /* … */ }

// On sign-out — clears the user binding + rotates the anonymous ID:
AppUser.logOut()
```

Define your own typed trait keys by conforming to `AppUserAttribute` (catches typos at compile time):

```swift
struct PlanTierTrait: AppUserAttribute {
    typealias Value = String
    var attributeName: String { "plan_tier" }
}

AppUser.set(PlanTierTrait(), "pro")
```

---

## Track events — `AppEvents`

```swift
AppEvents.track("AddHabitButtonTapped")
AppEvents.track("Purchase", attributes: [
    "sku": "pro_yearly",
    "price": 9.99,
    "currency": "USD"
])
```

Attributes are a loose `[String: Any]` — pass any dictionary (even one you already have from JSON) without converting values yourself. The SDK keeps everything JSON-compatible and **silently drops** anything that isn't. Kept: `String`, `Bool`, `Int`/`Int64`, `Double`/`Float`, `Decimal`, `Date`, `URL`, `UUID`, any custom `Codable` `GalvaCompatibleValue`, `NSNumber`/`NSString`/`NSNull`, and nested arrays/dictionaries of those. Dropped: custom classes, closures, and other non-JSON values.

For events you emit a lot, define a typed struct — the call site is a one-liner and the attributes are compile-time-checked (nothing is filtered):

```swift
struct PurchaseEvent: AppEvents.Event {
    let sku: String
    let price: Double
    var eventName: String { "Purchase" }
    var attributes: EventAttributes? { ["sku": sku, "price": price] }
}

AppEvents.track(PurchaseEvent(sku: "pro_yearly", price: 9.99))
```

`EventAttributes` is `[String: any GalvaCompatibleValue]` (`String`, `Int`, `Int64`, `Double`, `Float`, `Bool`, `Date`, `URL`, `UUID`, `Decimal`, or any custom `Codable & Sendable` type). Events are persisted to disk before they leave the SDK, so they survive crashes, kills, and offline windows, and retry with exponential backoff.

---

## Render in-app messages

This is how retention actually reaches the user. Galva polls for a pending message on every foreground (cold start + return from background) and publishes the highest-priority one. You render it; the SDK handles the bundle download, on-disk cache, the `WKWebView`, identity, and the native bridge (purchase prompt, dismissal, deep links).

### SwiftUI

**Zero-config** — drop one modifier on a root view and you're done:

```swift
import SwiftUI
import Galva

struct RootView: View {
    var body: some View {
        HomeView()
            .autoDisplayInAppMessages()
    }
}
```

**Controlled** — when you want to queue, filter by workflow, or gate on app state, drive the sheet from a binding (mirrors SwiftUI's own `.sheet(item:)`):

```swift
struct RootView: View {
    @State private var message: InAppMessages.Message?

    var body: some View {
        HomeView()
            .task {
                for await incoming in InAppMessages.messages {
                    // queue / filter by workflow / gate on app state, then:
                    message = incoming
                }
            }
            .inAppMessageSheet($message)
    }
}
```

The SDK clears the binding when the user dismisses (swipe-down or a bundle-driven close), so the sheet round-trips cleanly.

### UIKit

Consume `InAppMessages.messages` and call `show(in:)` with the active window scene. Start the loop once your scene is connected (e.g. in `SceneDelegate`):

```swift
import UIKit
import Galva

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var messageTask: Task<Void, Never>?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        messageTask = Task { @MainActor in
            for await message in InAppMessages.messages {
                guard let windowScene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                else { continue }
                try? await message.show(in: windowScene)
            }
        }
    }
}
```

`show(in:)` presents a managed sheet and is idempotent — calling it again with the same message while it's on screen is a no-op. It `throws` `InAppMessages.Error` (`.notConfigured`, `.messageNotFound`, `.bundleUnavailable`, `.bridgeProtocolMismatch`) — `try?` is fine for fire-and-forget rendering.

### Branching by workflow

Each message carries the workflow that triggered it, so you can theme, gate, or log per campaign:

```swift
// `InAppMessages.messages` is MainActor-isolated — iterate from a MainActor
// context so each message (and your UI work below) lands on the main thread.
Task { @MainActor in
    for await message in InAppMessages.messages {
        switch message.workflowType {
        case .trialRescue?:     break   // trial-to-paid nudge
        case .paymentRecovery?: break   // failed renewal
        case .prechurnSave?:    break   // about to cancel
        case nil:               break   // broadcast / manual send
        @unknown default:       break   // future workflow types
        }
        // …then present via .inAppMessageSheet($message) or message.show(in: scene)
    }
}
```

**Opting out of rendering** is just not consuming the stream — the SDK still polls (so suppression analytics stay accurate) but nothing appears.

---

## Push notifications

Galva sends push campaigns through APNs. Forward the device token in **one line** — pass the raw `Data` straight from the OS callback:

```swift
// AppDelegate — or an @UIApplicationDelegateAdaptor in SwiftUI.
func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Galva.applicationDidRegisterForRemoteNotificationsWithDeviceToken(deviceToken)
}
```

That's it. The token is **device-scoped**: Galva stores it and automatically keeps it associated with whoever is identified. You don't re-send it on login or logout — after `AppUser.identify(...)` or `AppUser.logOut()` the SDK re-registers the same token for the new user on its own, so every user the device serves stays reachable.

Requesting notification permission and registering with APNs (`UNUserNotificationCenter` / `registerForRemoteNotifications()`) stays in your hands — Galva never prompts on your behalf.

---

## Deep linking

When a user taps an email or push that links into your app, Galva can open the targeted message for you. Forward opened URLs to `Galva.handleOpenURL(_:)`.

**SwiftUI** — already wired. `.galvaConfigure(...)` attaches `onOpenURL` for you, so there's nothing else to do.

**UIKit / manual** — forward the URL, and use the return value to fall through to your own routing:

```swift
func application(_ app: UIApplication, open url: URL,
                options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    if Galva.handleOpenURL(url) { return true }   // Galva handled a gv… link
    return myRouter.open(url)                      // your app's own links continue here
}
```

`handleOpenURL` is **scheme-scoped**: it claims a URL only when the scheme starts with `gv` (your app's Galva link prefix) and returns `true`; for anything else — `https`, your own `myapp://`, `mailto:` — it returns `false` immediately and leaves the URL untouched. Adding Galva never swallows your existing links.

You don't author these URLs — Galva generates them when a workflow targets a user. The shipped route is `gv…://openCommunication?communicationId=…`, which opens that communication through the same in-app message flow (the SDK resolves the payload, downloads the bundle, and renders the `WKWebView`). All query parameters ride along into the page, so a tap carries its campaign context with it.

**Deferred until identify.** A targeted communication can only be resolved once Galva knows *who* the user is. If a deep link arrives before you've called `AppUser.identify(...)` (cold launch straight from a notification, before your session restore runs), the SDK **holds** it and replays it automatically the moment you identify — no work on your part. A returning user whose id was restored at launch resolves immediately. (If several arrive while waiting, the most recent wins.)

**Register the scheme** so iOS routes these URLs to your app — add your `gv…` scheme under **Target → Info → URL Types** (or in `Info.plist`):

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>gvYOURKEY</string></array>
  </dict>
</array>
```

> Your exact scheme is shown in the [Galva dashboard](https://galva.io) alongside your API key.

---

## Email

Set the user's email as a trait — it's validated client-side and an invalid address never reaches the server:

```swift
AppUser.set(.email, "peter@example.com")
```

Validation is basic RFC 5322: exactly one `@` with non-empty local + domain, a dotted domain, no whitespace. An invalid address is dropped before sending (the rest of the identify still goes through).

---

## Subscriptions & StoreKit

Galva doesn't own your transaction lifecycle — your existing StoreKit 2 / RevenueCat / billing observer does. Galva only needs to *attribute* purchases to the right user.

- **Link purchases to a user** by passing the StoreKit `appAccountToken` on identify:
  ```swift
  AppUser.identify(userId: "user_42", appAccountToken: subscriptionAccountToken)
  ```
- **Organic / restored purchases** (no `appAccountToken`) are reconciled automatically: on every foreground the SDK sweeps `Transaction.all` and maps `(originalTransactionId → userId)` so the backend can resolve App Store notifications. Force an off-cycle sweep after your own billing observer confirms a purchase, or behind a "Restore Purchases" button:
  ```swift
  Galva.reconcileTransactions()   // fire-and-forget, idempotent
  ```

In-app offer purchases initiated *inside* a Galva message are driven through StoreKit 2 by the SDK's native bridge, with the user's `appAccountToken` auto-attached — the result still lands in your app's `Transaction.updates` listener, which owns finishing the transaction.

---

## Privacy & opt-out

Give users a global kill switch for server-bound tracking:

```swift
Galva.setOptOut(true)    // stop all telemetry
Galva.isOptedOut          // synchronous read — safe in a SwiftUI body
```

When opted out: `track`, `identify`, and device-token / endpoint registration become silent no-ops, auto `session_start` is suppressed, StoreKit sweeps are skipped, and the on-disk event queue is **purged** on the opt-in → opt-out transition. The flag persists across launches (`UserDefaults`). In-app message polling/rendering continue using the anonymous ID.

**What the SDK collects:** an anonymous device UUID (first launch, stored locally); locale, timezone, OS/app version; and anything you explicitly send via `identify` / `track` / `set`.

**What it never does:** read the IDFA or prompt App Tracking Transparency; access contacts, photos, or location; swizzle UIKit / AppDelegate; or make any network call before `configure()`. Queued events live in `Application Support/Galva/`, excluded from iCloud Backup.

---

## Debugging

The SDK logs every action via Apple's `os.Logger`. Open **Console.app** (or watch Xcode's console) and filter:

```
subsystem:co.galva.sdk
```

| Category | What you'll see |
|---|---|
| `config` | configure lifecycle, logger installation |
| `identity` | every identify, track, logout, bridge call |
| `queue` | batching, draining, retries with backoff |
| `storage` | SQLite + schema migrations |
| `uploader` | every HTTP request + response status |
| `lifecycle` | cold start / background / foreground, sessions |

Crank up verbosity while integrating:

```swift
Galva.configure(apiKey: "...", logLevel: .debug)
```

At `.debug`, the SDK also **forwards the in-app message bundle's `console.*` output** (and uncaught JS errors) into the native log stream — so you can debug a hosted message from Xcode without attaching Safari Web Inspector.

Pipe Galva logs into your own stack (Sentry, Crashlytics, Datadog, a file) by implementing `GalvaLogger`:

```swift
struct CrashlyticsBreadcrumbs: GalvaLogger {
    func log(_ entry: Galva.LogEntry) {
        Crashlytics.crashlytics().log("[\(entry.category.rawValue)] \(entry.message)")
    }
}

Galva.setLogger(CrashlyticsBreadcrumbs())
```

The configured `logLevel` filter still applies — your sink only sees entries that pass it.

---

## Performance

The SDK is built to be invisible to your app's perf budget:

- **API calls return in microseconds.** Every entry point hops to a background actor and returns; your UI thread never waits.
- **No main-thread work after `configure()`.** A one-time device snapshot is captured off-main at startup.
- **Bounded local queue.** Pending events are capped (~10 MB worst case) and evicted FIFO when offline long enough to hit the cap — never unbounded growth.
- **Bounded retries.** Failed batches use exponential backoff with jitter capped at 60s — no busy-loop on outages.
- **No iCloud Backup pressure.** SQLite lives in `Application Support/Galva/` with the no-backup flag set.

Every guarantee is locked in by contract tests in CI.

---

## Requirements

| | |
|---|---|
| **Deployment target** | iOS 15.0+ · macOS 12.0+ |
| **Build toolchain** | Xcode 26+ (iOS 26 SDK) |
| **Frameworks** | StoreKit 2 + WebKit (system) — no third-party dependencies |

---

## Links

- **Galva platform** — [galva.io](https://galva.io)
- **Releases** — [GitHub Releases](https://github.com/Galva-io/galva-ios/releases)
- **Contributing** — [CONTRIBUTING.md](CONTRIBUTING.md)

## License

MIT — see [LICENSE](LICENSE) for the full text.
