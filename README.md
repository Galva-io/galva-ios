# Galva iOS SDK

[Galva](https://galva.io) recovers the subscribers your app is about to lose: trials that won't convert, subscribers who turn off auto-renew, and lapsed subscribers you can win back. Your growth team builds recovery flows of email, push and in-app messages with App Store offers in Galva, and changes them without a release.

This SDK connects your iOS app to Galva. It identifies subscribers, shows Galva's in-app messages, buys the offers in them, and ties App Store purchases to the right subscriber.

**iOS 15+ · Xcode 26+ · Swift Package Manager · no third-party dependencies**

📖 Full documentation: **[docs.galva.io/sdks/ios](https://docs.galva.io/sdks/ios/install)**

---

## Quick start

You need a Galva account with your app added. If you don't have one yet, [schedule a demo](https://galva.io/demo).

### 1. Register your app in Galva

In Galva, open **Admin → Settings → Connect → Client SDKs**, select **Register new Client** and choose **iOS**. Copy two values from the new client:

- **App ID**, which starts with `pk_`. It's the key you pass to the SDK, and it's safe to ship in your app.
- **URL scheme**, which starts with `gv-`. It's under **Integrate → Show integration guide**.

### 2. Add the package

In Xcode, choose **File → Add Package Dependencies…**, paste the URL below, pick **Up to Next Major Version**, and add the **Galva** library to your app target.

```
https://github.com/Galva-io/galva-ios
```

<details>
<summary>Using <code>Package.swift</code> instead</summary>

```swift
dependencies: [
    .package(url: "https://github.com/Galva-io/galva-ios", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Galva", package: "galva-ios")]),
]
```

</details>

### 3. Configure Galva

Call `Galva.configure` once at launch. From then on, Galva presents its in-app messages on its own, as a sheet on your app's active window.

In SwiftUI, configure Galva in your `App` initializer, and forward Galva links from your root view:

```swift
import SwiftUI
import Galva

@main
struct MyApp: App {
    init() {
        Galva.configure(apiKey: "pk_your_app_id")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in Galva.handleOpenURL(url) }  // opens Galva links
        }
    }
}
```

<details>
<summary>UIKit</summary>

Configure Galva in your app delegate:

```swift
func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
    Galva.configure(apiKey: "pk_your_app_id")
    return true
}
```

Forward Galva links from your scene delegate:

```swift
func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
) {
    Galva.scene(scene, willConnectTo: session, options: connectionOptions)
}

func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    Galva.scene(scene, openURLContexts: URLContexts)
}
```

Apps without scenes forward links with `Galva.application(_:didFinishLaunchingWithOptions:)` and `Galva.application(_:open:options:)`. See [Handle deep links](https://docs.galva.io/sdks/ios/deep-links).

</details>

Replace `pk_your_app_id` with your App ID. While you integrate, add `logLevel: .debug` to see everything the SDK does. To decide yourself when messages appear, see [Present messages yourself](#present-messages-yourself).

### 4. Identify subscribers

Identify with the user ID your backend and subscription data already use, after sign-in and when your app restores a signed-in session:

```swift
AppUser.identify(userId: "user_42")
AppUser.set(.email, "alex@example.com")

// When the subscriber signs out:
AppUser.logOut()
```

Using RevenueCat? Skip this step and add the [RevenueCat integration](#using-revenuecat) instead.

### 5. Register your URL scheme

So **Continue in App** on Galva's offer page opens your app, add your `gv-` scheme under your target's **Info → URL Types**, or in `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array><string>gv-your-scheme</string></array>
    </dict>
</array>
```

Galva only claims URLs whose scheme starts with `gv`. Your own links pass through untouched.

### 6. Finish offer purchases

When a subscriber redeems an offer in a Galva message, the SDK buys it with StoreKit and leaves the transaction **unfinished** for your code. StoreKit doesn't hand that transaction to your `Transaction.updates` listener until the next launch, so process unfinished transactions at launch and whenever your app becomes active:

```swift
for await result in Transaction.unfinished {
    guard case .verified(let transaction) = result else { continue }
    // Give the subscriber access to transaction.productID, then:
    await transaction.finish()
}
```

If your app also starts purchases itself, attach Galva's token so they're matched to the subscriber:

```swift
let token = AppUser.appAccountToken
let result = try await product.purchase(options: token.map { [.appAccountToken($0)] } ?? [])
```

### 7. Connect your subscription data

The SDK tells Galva who your subscribers are. Your subscription data tells it when they start, cancel, renew and expire. In Galva, open **Admin → Settings → Connect → Billing Connections** and connect the [App Store](https://docs.galva.io/integrations/app-store), [RevenueCat](https://docs.galva.io/integrations/revenuecat) or [your own backend](https://docs.galva.io/integrations/backend). Then map your products to plans in **Catalog → Products**.

### 8. Check it works

Run your app with `logLevel: .debug`, sign in, and filter Console.app or Xcode's console on:

```
subsystem:co.galva.sdk
```

You should see `SDK configured`, `endUserId changed from=<anonymous> to=user_42` and `uploaded batch`. In Galva, your client under **Client SDKs** now shows a **Last seen** time.

---

## Push notifications

Add your APNs key in Galva under **Admin → Settings → Communication → Push Notifications**, then forward the device token from your app delegate:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Galva.applicationDidRegisterForRemoteNotificationsWithDeviceToken(deviceToken)
}
```

Asking for permission and registering for remote notifications stay in your app; Galva never prompts. To report taps on Galva notifications, see [Send push tokens](https://docs.galva.io/sdks/ios/push).

## Present messages yourself

By default Galva presents each in-app message as soon as it's ready. To decide when and where messages appear, for example only after onboarding, configure `.manual`. Galva then doesn't present the messages it fetches; your app reads them from `InAppMessages.messages` and presents them. A Galva link the user opens, such as "Continue in App" in an email, still presents its message right away, because the user asked for it.

```swift
Galva.configure(apiKey: "pk_your_app_id", inAppMessages: .manual)
```

In SwiftUI, read the stream into state and present it with `.inAppMessageSheet`:

```swift
struct RootView: View {
    @State private var message: InAppMessages.Message?

    var body: some View {
        ContentView()
            .task {
                for await incoming in InAppMessages.messages {
                    message = incoming
                }
            }
            .inAppMessageSheet($message)
    }
}
```

In UIKit, read the stream and call `show()`, which presents on your app's active window:

```swift
Task { @MainActor in
    for await message in InAppMessages.messages {
        try? await message.show()
    }
}
```

To filter, check `message.workflowType`, the recovery flow that sent the message. To wait, keep the message and present it later. A message that arrives before your loop starts is held and handed to it when it does, so starting the loop a moment after launch is fine. Present each message in one place.

## Using RevenueCat

Add the [GalvaRevenueCat](https://github.com/Galva-io/galva-ios-revenuecat) package and pass its integration to `configure`:

```swift
import Galva
import GalvaRevenueCat
import RevenueCat

Purchases.configure(withAPIKey: "appl_your_key")
Galva.configure(apiKey: "pk_your_app_id", integrations: [.revenueCat()])
```

The integration keeps Galva's subscriber in step with RevenueCat's app user ID, so you don't call `AppUser.identify`. It also runs offer purchases from Galva's messages through RevenueCat, so entitlements unlock right away and RevenueCat finishes the transaction. Connect RevenueCat under **Billing Connections** as well, so Galva receives your subscription events.

## Your own billing code

If your app runs its own StoreKit pipeline, Galva can hand it the offer purchases from its messages, so your code records and finishes them in the same session. Implement `GalvaPurchaseController` and install it:

```swift
struct MyPurchaseController: GalvaPurchaseController {
    @MainActor
    func purchase(_ request: Galva.PurchaseRequest) async throws -> Galva.PurchaseResult {
        // Galva's StoreKit purchase, with the signed offer and the subscriber's token attached.
        switch try await request.purchaseWithStoreKit() {
        case .success(.verified(let transaction)):
            await MyStore.shared.unlock(transaction)
            await transaction.finish()
            return .completed(transaction)
        case .success(.unverified(_, let error)):
            throw Galva.PurchaseError.verificationFailed(String(describing: error))
        case .pending:
            return .pending
        default:
            return .cancelled
        }
    }
}

Galva.setPurchaseController(MyPurchaseController())
```

You can also buy through your own purchase API instead of `purchaseWithStoreKit()` and return the verified transaction. Throw a `Galva.PurchaseError` so the message shows the right state.

## How the SDK behaves

- **It never blocks your app.** Every call returns immediately and does its work on a background actor.
- **Calls aren't lost.** Calls you make right after `configure`, while it's still starting, wait for it and run in order. Everything is saved to disk before upload and retried with backoff, so it survives crashes, app kills and offline periods.
- **It stays out of your way.** No method swizzling, no IDFA or tracking prompt, and no network call before `configure`.
- **It declares its data use.** The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) listing the data it collects and its one required-reason API, `UserDefaults`, so Xcode's privacy report for your app includes it.
- **Subscribers can opt out.** `Galva.setOptOut(true)` stops tracking; in-app messages keep working. See [Privacy and App Review](https://docs.galva.io/sdks/ios/privacy).

## Documentation

| Guide | Covers |
|---|---|
| [Install and configure](https://docs.galva.io/sdks/ios/install) | Environments, log levels, custom loggers, automatic tracking |
| [Identify subscribers](https://docs.galva.io/sdks/ios/identify) | Anonymous IDs, logging out, RevenueCat's app user ID |
| [Set attributes and track events](https://docs.galva.io/sdks/ios/attributes) | Built-in and custom attributes, typed events |
| [Show in-app messages](https://docs.galva.io/sdks/ios/in-app-messages) | Holding and filtering messages, UIKit presentation |
| [Handle deep links](https://docs.galva.io/sdks/ios/deep-links) | Every UIKit entry point, keeping your own routing |
| [Send push tokens](https://docs.galva.io/sdks/ios/push) | Tokens, taps and dismissals |
| [Purchases and store offers](https://docs.galva.io/sdks/ios/purchases) | App account tokens and offer purchases |
| [Test your integration](https://docs.galva.io/sdks/ios/testing) | Checking identity, purchases, messages and push before release |
| [Privacy and App Review](https://docs.galva.io/sdks/ios/privacy) | Your privacy manifest and App Privacy answers |
| [Logs and troubleshooting](https://docs.galva.io/sdks/ios/troubleshooting) | Reading the SDK's logs, matching symptoms to fixes |
| [Swift API reference](https://docs.galva.io/sdks/ios/reference) | Every public type and method |

## Requirements

| | |
|---|---|
| **iOS** | 15.0 or later |
| **Xcode** | 26 or later. The SDK uses a StoreKit API from the iOS 26 SDK for offer purchases; your app still runs on iOS 15. |
| **Install** | Swift Package Manager only. There's no prebuilt framework or CocoaPods pod. |

## Example app

[`Examples/GalvaDemo`](Examples/GalvaDemo) is a SwiftUI app that integrates the SDK end to end, with UI tests that drive in-app messages, deep links and identity against an in-process mock. See its [README](Examples/GalvaDemo/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report bugs and request features in [GitHub Issues](https://github.com/Galva-io/galva-ios/issues).

## License

MIT. See [LICENSE](LICENSE).
