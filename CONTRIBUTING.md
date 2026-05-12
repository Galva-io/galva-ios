# Contributing to the Galva iOS SDK

Thanks for digging into the SDK internals. This doc is for people working **on** the SDK; if you're integrating Galva into your iOS app, [README.md](README.md) is the right place.

---

## Repo layout

```
Sources/
├── Galva.swift                 ← public API surface
├── Internal/                   ← SDKCore, IdentityStore, UUIDv7, SDKConstants
├── Messages/                   ← MessageQueue, SQLite/InMemory storage,
│                                 StorageMigrator (schema + quarantine)
├── Models/                     ← AnyJSONValue, MessageContext, Endpoint
├── Networking/                 ← Uploader, UploadConsumer
└── Logger/                     ← GalvaLogger, OSLogLogger, LevelFilter

Tests/
├── MessageQueueTests/          ← queue contracts, resilience, durability
├── ModelsTests/                ← Codable round-trips
├── InternalTests/              ← UUIDv7, Backoff, SDKCore integration
├── NetworkingTests/            ← Uploader (URLProtocolStub), UploadConsumer
├── LoggerTests/                ← level filtering, format, SDK breadcrumbs
└── PerformanceTests/           ← contract tests (latency, queue cap, etc.)

scripts/
├── lint.sh                     ← canonical perf-hazard + crash-pattern checks
└── build-xcframework.sh        ← release XCFramework builder

.github/workflows/
├── ci.yml                      ← lint + test on every PR
└── release.yml                 ← build + publish XCFramework on tag

.swiftlint.yml                  ← optional richer rules (if you install SwiftLint)
```

---

## Local development

```bash
swift build
swift test                      # ~20s, 200+ tests
./scripts/lint.sh               # host-app perf hazards, crash patterns
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
| `PerformanceContractTests` | API return latency, queue cap, filtered-log cost |
| `Uploader*Tests` | HTTP request shape + status classification via `URLProtocolStub` |

Pure-logic suites (Codable, UUIDv7, Backoff) live alongside the source they cover.

Avoid wall-clock-dependent assertions. Use the `eventually(timeout:condition:)` helper in [`TestSupport.swift`](Tests/MessageQueueTests/TestSupport.swift) instead — passes immediately when the condition holds, only fails on timeout.

---

## Architecture notes worth knowing

### Two SPM products

[`Package.swift`](Package.swift) declares two library products:

```swift
.library(name: "Galva",         targets: ["Galva"]),                    // static — SPM consumers
.library(name: "Galva_dynamic", type: .dynamic, targets: ["Galva"]),    // dynamic — XCFramework only
```

Why two: `xcodebuild archive` against a static SPM product produces a single `.o` file, not a `.framework` bundle. To get a framework for the XCFramework, we need a dynamic product. SPM consumers ignore `Galva_dynamic` (the static `Galva` is what their dependency graph picks). The XCFramework script archives `Galva_dynamic` and renames the resulting framework to `Galva.framework` for distribution.

RevenueCat, Sentry, and similar SDKs ship a separate wrapper Xcode project to solve the same problem. The naming hack is simpler — same end result with one fewer file to maintain.

### `-no-verify-emitted-module-interface` in the XCFramework build

When the module name (`Galva`) matches a top-level public type name (`enum Galva`), Swift's swiftinterface verifier emits `Galva.Galva.LogCategory` references that fail self-verification. The emitted interface is functionally consumable by downstream code; only the verifier false-positives. The XCFramework build passes `OTHER_SWIFT_FLAGS=-no-verify-emitted-module-interface` to skip the broken check.

If the Swift compiler ever fixes this collision, drop the flag.

### SQLite schema migrations

Pending messages from older SDK builds must survive upgrades. The full framework + runbook lives in the header of [`Sources/Messages/StorageMigrator.swift`](Sources/Messages/StorageMigrator.swift) — **read it before changing the SQLite schema or the message wire format**.

Short version:
- **Optional JSON field?** Just add it. Codable handles missing keys as nil.
- **New SQLite column / table / index?** Bump `currentVersion`, add a migration arm, add a fixture test.
- **Anything more disruptive?** See the file header.

### Logger pipeline

Public surface in [`Sources/Logger/Logger.swift`](Sources/Logger/Logger.swift). All internal call sites use the typed convenience methods (`logger.warning(.uploader, "…")`) — `lint.sh` enforces no raw `print`.

Default sink is `OSLogLogger`, writing to subsystem `co.galva.sdk` (visible in Console.app). Custom loggers are wrapped in `LevelFilterLogger` so the `logLevel` set at configure time always applies, even after `Galva.setLogger(_:)`.

The convenience methods short-circuit on filtered levels (an `isEnabled(_:)` check runs before the autoclosure message is evaluated) — a `logger.debug(.queue, "expensive \(work)")` in a hot loop costs ~zero when filtered out. Locked in by `FilteredLogPerformanceTests`.

---

## Release process

Each tagged release ships two artifacts: the source SPM tag itself, and `Galva.xcframework.zip` attached to the GitHub Release.

### Cutting a release

```bash
git tag v1.2.3
git push --tags
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) does the rest:

1. Re-runs `lint.sh` + `swift test` against the tagged commit (cheap insurance).
2. Builds the XCFramework via `scripts/build-xcframework.sh`.
3. Creates / updates the GitHub Release with auto-generated install snippets for all three paths (source SPM, drag-and-drop XCFramework, binary-target SPM).
4. Uploads `Galva.xcframework.zip` and the SPM checksum.

To re-run the release for an existing tag (e.g. you fixed something in the build script), trigger the workflow manually via the Actions UI and pass the tag name as input. `--clobber` on the upload step replaces existing assets.

### Building the XCFramework locally

```bash
./scripts/build-xcframework.sh
```

Outputs `build/Galva.xcframework`, `build/Galva.xcframework.zip`, and a checksum file. Takes ~30s. Useful for smoke-testing the build before tagging.

### CI

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on every PR + push to `main`:

- `lint` — `scripts/lint.sh`
- `test` — `swift test --parallel`

Both must pass for a PR to be mergeable (set up the branch protection rule under **Settings → Branches**).

---

## Performance contract

The SDK's perf-safety story is locked in by tests in `Tests/PerformanceTests/`:

| Contract | Test |
|---|---|
| `AppEvents.track` returns in microseconds | `test_track_returnsSynchronouslyAndQuickly` |
| `AppUser.identifiedUserId` read is fast | `test_identifiedUserId_isCheapSyncRead` |
| Queue cap evicts oldest | `test_queueRespectsMaxStoredCount_evictsOldest` |
| Filtered logs skip the autoclosure | `test_filteredOutEntries_doNotInvokeMessageClosure` |

Loose bounds (50µs / 5µs ceilings) catch orders-of-magnitude regressions without flaking on slow CI.

When adding new code on a hot path, lock the contract here too.

---

## Questions

Open an issue or ping the team. Internal Slack is `#sdk-ios`.
