# Changelog

All notable changes to the Galva iOS SDK are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the SDK follows [Semantic Versioning](https://semver.org/).

Minor releases may add values to `InAppMessages.WorkflowType` and `Galva.LogCategory`, and cases to `InAppMessages.Error` and `Galva.PurchaseError`. Switch on those with a `default` or `@unknown default` case.

## [1.0.0] - Unreleased

First public release.

### Added

- **Setup:** `Galva.configure(apiKey:)` and the SwiftUI `.galvaConfigure(apiKey:)` modifier, with production, development and custom environments, log levels, custom loggers (`GalvaLogger`), and automatic `session_start` and Apple Search Ads attribution.
- **Subscribers:** `AppUser.identify(userId:appAccountToken:)`, `AppUser.logOut()`, built-in and custom attributes with `AppUser.set`, and synchronous `AppUser.identifiedUserId` and `AppUser.appAccountToken`.
- **Events:** `AppEvents.track`, including typed events. Calls are saved to disk and uploaded in batches, with retry and backoff.
- **In-app messages:** `.autoDisplayInAppMessages()`, `.inAppMessageSheet(_:)`, `InAppMessages.messages` with `show(in:)`, and `InAppMessages.checkForMessages()`. Offers in messages are bought with StoreKit, with Galva-signed promotional offers and the subscriber's app account token. `InAppMessages.WorkflowType` carries any workflow type, including ones Galva adds after this release.
- **Deep links:** your app's `gv-` URL scheme opens Galva's messages and offers. `.galvaConfigure` forwards links automatically; UIKit apps forward them from their app and scene delegates.
- **Push:** device token registration, and tap and dismiss tracking for Galva's notifications.
- **Purchases:** `Galva.reconcileTransactions()` and an automatic StoreKit transaction sweep match purchases to subscribers.
- **Purchase controllers:** `GalvaPurchaseController` and `Galva.setPurchaseController(_:)` run offer purchases through your own billing code.
- **Integrations:** `Galva.configure(…, integrations:)` connects packages such as [GalvaRevenueCat](https://github.com/Galva-io/galva-ios-revenuecat).
- **Privacy:** `Galva.setOptOut(_:)`, and a privacy manifest (`PrivacyInfo.xcprivacy`) that declares the SDK's collected data and its `UserDefaults` use.

[1.0.0]: https://github.com/Galva-io/galva-ios/releases/tag/v1.0.0
