# Changelog

All notable changes to the Galva iOS SDK are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the SDK follows [Semantic Versioning](https://semver.org/).

Minor releases may add values to `InAppMessages.WorkflowType` and `Galva.LogCategory`, and cases to `InAppMessages.Error` and `Galva.PurchaseError`. Switch on those with a `default` or `@unknown default` case.

## [1.0.0] - Unreleased

First public release.

### Added

- **Setup:** `Galva.configure(apiKey:)`, with production, development and custom environments, log levels, log categories (including `.inAppMessages` and `.purchases`) for Console.app filtering, custom loggers (`GalvaLogger`), and automatic `session_start` and Apple Search Ads attribution.
- **Subscribers:** `AppUser.identify(userId:appAccountToken:)`, `AppUser.logOut()`, built-in and custom attributes with `AppUser.set`, and synchronous `AppUser.identifiedUserId` and `AppUser.appAccountToken`. `Galva.AppUser`, `Galva.AppEvents` and `Galva.InAppMessages` name the same types for apps that have their own type with one of those names.
- **Events:** `AppEvents.track`, including typed events. Calls are saved to disk and uploaded in batches, with retry and backoff.
- **In-app messages:** Galva presents each message automatically, as a sheet on the app's active window. With `inAppMessages: .manual`, your app reads `InAppMessages.messages` and presents them itself, with `.inAppMessageSheet(_:)` in SwiftUI or `message.show()` in UIKit, which throws an `InAppMessages.Error` when a message can't be shown. A message that arrives before the app starts reading is held for it, and one that can't be shown for a reason that may clear up, such as no network, can be delivered again the next time the app becomes active. `InAppMessages.checkForMessages()` checks on demand. Offers in messages are bought with StoreKit, with Galva-signed promotional offers and the subscriber's app account token. `InAppMessages.WorkflowType` carries any workflow type, including ones Galva adds after this release.
- **Deep links:** your app's `gv-` URL scheme opens Galva's messages and offers. SwiftUI apps forward links with `.onOpenURL { url in Galva.handleOpenURL(url) }`; UIKit apps forward them from their app and scene delegates.
- **Push:** device token registration, and tap and dismiss tracking for Galva's notifications.
- **Purchases:** `Galva.reconcileTransactions()` and an automatic StoreKit transaction sweep match purchases to subscribers.
- **Purchase controllers:** `GalvaPurchaseController` and `Galva.setPurchaseController(_:)` run offer purchases through your own billing code.
- **Integrations:** `Galva.configure(…, integrations:)` connects packages such as [GalvaRevenueCat](https://github.com/Galva-io/galva-ios-revenuecat).
- **Privacy:** `Galva.setOptOut(_:)`, and a privacy manifest (`PrivacyInfo.xcprivacy`) that declares the SDK's collected data and its `UserDefaults` use.

[1.0.0]: https://github.com/Galva-io/galva-ios/releases/tag/v1.0.0
