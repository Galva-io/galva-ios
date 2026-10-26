# Contributing to the Galva iOS SDK

Thanks for digging into the SDK internals. This doc is for people working **on** the SDK; if you're integrating Galva into your iOS app, [README.md](README.md) is the right place.

---

## Repo layout

```
Sources/
├── Galva.swift                 ← public API: Galva, AppEvents, AppUser, InAppMessages
├── Galva+*.swift               ← public API extensions: deep links, notifications,
│                                 purchase controllers, integrations
├── Internal/                   ← SDKCore, IdentityStore, deep links, sessions,
│                                 Apple Search Ads, UUIDv7, SDKConstants
├── InAppMessages/              ← message manager + presenter, WebView, native bridge,
│                                 StoreKit purchaser + product prefetcher
├── Initialization/             ← /sdk/initialize client + on-disk cache
├── Transactions/               ← Transaction.all sweep (purchase → user mapping)
├── Messages/                   ← MessageQueue, SQLite/InMemory storage,
│                                 StorageMigrator (schema + quarantine)
├── Models/                     ← AnyJSONValue, MessageContext, Endpoint
├── Networking/                 ← APIClient, Uploader, durable request queue
├── SwiftUI/                    ← .inAppMessageSheet, for .manual presentation
└── Logger/                     ← GalvaLogger, OSLogLogger, LevelFilter

Tests/                          ← one folder per area, mirroring Sources/

Examples/GalvaDemo/             ← SwiftUI demo app + XCUITest E2E and perf suites
                                  (Tuist project; regenerate with `tuist generate`)

scripts/
├── lint.sh                     ← canonical perf-hazard + crash-pattern checks
├── e2e.sh                      ← generates the demo project, runs the UI tests
└── perf.sh                     ← measures SDK overhead against a no-SDK baseline

.github/workflows/
├── ci.yml                      ← lint, unit tests, E2E and perf on every PR
└── notify-react-native.yml     ← tells galva-react-native about a new tag

cocoapods/galva-build.rb        ← build settings for galva-react-native's vendored pod
.swiftlint.yml                  ← optional richer rules (if you install SwiftLint)
```

---

## Local development

Galva builds with **Xcode 26 or later**: the StoreKit offer path uses an iOS 26 SDK API, back-deployed so apps still run on iOS 15.

```bash
swift build
swift test                      # 440+ tests, ~15s once built
./scripts/lint.sh               # host-app perf hazards, crash patterns
./scripts/e2e.sh                # UI tests against an in-process mock (needs Tuist)
./scripts/perf.sh               # SDK overhead report (needs Tuist)
```

Open `Package.swift` directly in Xcode to get the SwiftPM-generated workspace.

If you install SwiftLint (`brew install swiftlint`) and run `swiftlint`, you'll get richer rules layered on top of `lint.sh` — see [`.swiftlint.yml`](.swiftlint.yml). It's optional; `lint.sh` is the canonical floor and the only thing CI requires.

---

## Code style

Enforced by `scripts/lint.sh`:

- **No third-party dependencies in `Sources/`.** System frameworks only.
- **Never block the host app's main thread.** No `DispatchQueue.main.sync`, `Thread.sleep`, `DispatchSemaphore`, or `RunLoop.run(until:)` in production code.
- **Use the logger, not `print`/`debugPrint`/`NSLog`.** Those bypass the configured `GalvaLogger` pipeline.
- **No `try!` / `as!` / `fatalError` in production code.** The SDK must never crash the host.
- **No force-unwraps on String-input initializers** (`URL(string:)!`, `UUID(uuidString:)!`, etc.) without a `// galva-lint:disable reason="…"` comment justifying it.

When a rule needs an exception, add a same-line comment with a reason:

```swift
let url = URL(string: "https://api.galva.dev")! // galva-lint:disable reason="hardcoded build-time constant"
```

Per-file disables are not supported — every exception needs a reviewable in-line justification.

---

## Tests

The suite is organised by behavioural contract, not by source-file mirror. When fixing a bug, write the test under the contract it broke:

| Suite | What it pins |
|---|---|
| `MessageQueueContractTests` | FIFO order, batching by count/time, batch-cap, no-batching mode |
| `MessageQueueResilienceTests` | failures retain the batch, backoff bounds, recovery |
| `MessageQueueConcurrencyTests` | concurrent producers preserve count + order, no duplicates |
| `MessageQueueLifecycleTests` | start/stop/clear idempotency, restart drains the backlog |
| `MessageQueueDurabilityTests` | restart with same SQLite path replays pending messages |
| `MessageStorageContractTests` | shared contract both InMemory + SQLite must satisfy |
| `StorageMigrationTests` | schema migrations, quarantine, downgrade safety |
| `SDKCore*Tests` | integration tests using `SDKHarness` (no network, no real disk) |
| `InAppMessage*Tests`, `Bridge*Tests` | message delivery (automatic and manual), display budget, native bridge wire format |
| `PurchaseControllerTests` | purchase-controller dispatch and bridge error codes |
| `IntegrationSPITests` | the `@_spi` surface integration packages build on |
| `PublicAPIReturnLatencyTests`, `BoundedQueueTests`, `FilteredLogPerformanceTests`, `MainThreadBudgetTests` | API return latency, queue cap, filtered-log cost, main-thread budgets |
| `Uploader*Tests` | HTTP request shape + status classification via `URLProtocolStub` |

Pure-logic suites (Codable, UUIDv7, Backoff) live alongside the source they cover.

Avoid wall-clock-dependent assertions. Use the `eventually(timeout:condition:)` helper in [`TestSupport.swift`](Tests/MessageQueueTests/TestSupport.swift) instead — passes immediately when the condition holds, only fails on timeout.

---

## Architecture notes worth knowing

### One SPM product, source only

[`Package.swift`](Package.swift) declares a single `Galva` library product. Galva ships as source through Swift Package Manager only — no XCFramework, no CocoaPods trunk pod — and SwiftPM / the consuming target decides static vs dynamic linking.

The swift-tools-version stays at 6.0 so the manifest parses on every Xcode that can build the SDK; don't use newer manifest features without bumping it deliberately.

### Public value sets that grow are structs

SwiftPM builds this package from source, without library evolution, so adding a case to a public enum breaks every app that switches over it exhaustively. Sets that grow with the product, like `InAppMessages.WorkflowType` and `Galva.LogCategory`, are `RawRepresentable` structs with static values instead: adding one is a minor release, and an unknown server value still decodes.

Public error enums (`InAppMessages.Error`, `Galva.PurchaseError`) stay enums. Their docs tell apps to switch with `@unknown default`, which turns a new case into a warning rather than a build failure, so they may gain cases in minor releases too. Closed sets (`Galva.LogLevel`, `Galva.Environment`, `Galva.PurchaseResult`) are plain enums.

### Integrations live in their own packages

SDKs that integrate with another vendor's SDK (e.g. [`galva-ios-revenuecat`](https://github.com/Galva-io/galva-ios-revenuecat)) are separate packages. SwiftPM fetches and pins every dependency a package declares, even ones only used by products an app doesn't link, so a vendor dependency in this `Package.swift` would reach every Galva app.

Integration packages plug in through `Galva.configure(…, integrations:)`. They build a `Galva.Integration` with the `@_spi(GalvaIntegration)` initializer and log through the `GalvaLogger` convenience methods, which are `@_spi(GalvaIntegration)` too. Their unit tests build `@_spi(Testing)` values: `Galva.PurchaseRequest`, `Galva.PromotionalOffer` and `Galva.IntegrationContext`. `IntegrationSPITests` pins that surface, so changing it breaks a test here before it breaks an integration package.

### React Native vendors this source

[`galva-react-native`](https://github.com/Galva-io/galva-react-native) compiles a pinned snapshot of `Sources/` into its own CocoaPods pod, using the build settings in [`cocoapods/galva-build.rb`](cocoapods/galva-build.rb). When you change `Package.swift`'s platforms, Swift version or linker settings, update that file in the same commit. Wrappers report their own identity through the internal `Galva.configure(…, wrapper:)` seam.

### SQLite schema migrations

Pending messages from older SDK builds must survive upgrades. The full framework + runbook lives in the header of [`Sources/Messages/StorageMigrator.swift`](Sources/Messages/StorageMigrator.swift) — **read it before changing the SQLite schema or the message wire format**.

Short version:
- **Optional JSON field?** Just add it. Codable handles missing keys as nil.
- **New SQLite column / table / index?** Bump `currentVersion`, add a migration arm, add a fixture test.
- **Anything more disruptive?** See the file header.

### Logger pipeline

Public surface in [`Sources/Logger/Logger.swift`](Sources/Logger/Logger.swift); apps implement only `log(_:)`. All internal call sites use the typed convenience methods (`logger.warning(.uploader, "…")`), `@_spi(GalvaIntegration)` so integration packages can use them too — `lint.sh` enforces no raw `print`.

Default sink is `OSLogLogger`, writing to subsystem `co.galva.sdk` (visible in Console.app). Custom loggers are wrapped in `LevelFilterLogger` so the `logLevel` set at configure time always applies, even after `Galva.setLogger(_:)`. Integrations get the same live logger as the SDK's own subsystems, so their output follows later level and logger changes too.

The convenience methods short-circuit on filtered levels (an `isEnabled(_:)` check runs before the autoclosure message is evaluated) — a `logger.debug(.queue, "expensive \(work)")` in a hot loop costs ~zero when filtered out. Locked in by `FilteredLogPerformanceTests`.

---

## Release process

A release is a Git tag on `main`. SwiftPM resolves it directly; there are no binary artifacts to build or upload.

### Cutting a release

1. Bump `version` in [`Sources/Internal/SDKConstants.swift`](Sources/Internal/SDKConstants.swift). It's reported in the `x-sdk-version` header and by `Galva.sdkVersion`, so it must match the tag.
2. In [`CHANGELOG.md`](CHANGELOG.md), give the release its version and date, and list its changes. Merge PRs with a CHANGELOG line for anything an app developer would notice.
3. Merge to `main` with CI green.
4. Tag and push:

   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```

5. Create the GitHub Release with notes:

   ```bash
   gh release create v1.2.3 --generate-notes
   ```

Pushing a tag also runs [`notify-react-native.yml`](.github/workflows/notify-react-native.yml), which asks `galva-react-native` to open a bump-and-re-vendor PR.

Integration packages depend on a released version of this SDK, so release here first, then update and release them.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every PR + push to `main`:

- `lint` — `scripts/lint.sh`
- `test` — `swift test --parallel`
- `test-ios` — `xcodebuild test` on an iOS Simulator, which also runs the UIKit / WebKit tests `swift test` on macOS doesn't build
- `e2e` — `scripts/e2e.sh`, the demo app's UI tests against an in-process mock
- `perf` — `scripts/perf.sh`, which fails if the SDK's memory overhead passes its budget

All must pass for a PR to be mergeable (set up the branch protection rule under **Settings → Branches**).

---

## Performance contract

The SDK's perf-safety story is locked in by tests in `Tests/PerformanceTests/`:

| Contract | Test |
|---|---|
| `AppEvents.track` returns in microseconds | `test_track_returnsSynchronouslyAndQuickly` |
| `AppUser.identifiedUserId` read is fast | `test_identifiedUserId_isCheapSyncRead` |
| Queue cap evicts oldest | `test_queueRespectsMaxStoredCount_evictsOldest` |
| Filtered logs skip the autoclosure | `test_filteredOutEntries_doNotInvokeMessageClosure` |

Loose bounds (50µs / 5µs ceilings) catch orders-of-magnitude regressions without flaking on slow CI. `scripts/perf.sh` measures the real overhead in the demo app (memory, launch, CPU) against a baseline without the SDK.

When adding new code on a hot path, lock the contract here too.

---

## Questions

Open an issue or ping the team. Internal Slack is `#sdk-ios`.
