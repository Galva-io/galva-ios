# GalvaDemo — example app & end-to-end tests

A real SwiftUI app that integrates the Galva SDK exactly as a host app would
(`.galvaConfigure(...)` + `.autoDisplayInAppMessages()`), plus an XCUITest
suite that drives the **full stack** — configure → poll → resolve → bundle
download → `WKWebView` → native bridge → deep link — and asserts behavior.

The app links the local `Galva` SPM package straight from the repo root, so it
consumes the SDK the same way an integrator does (no XCFramework, no copy).

## Run the automated E2E suite

```sh
# from the repo root
./scripts/e2e.sh
# or target a specific simulator:
GALVA_E2E_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro' ./scripts/e2e.sh
```

This generates the Xcode project with Tuist and runs the UI tests. It also
runs in CI (the `e2e` job in `.github/workflows/ci.yml`).

Requires [Tuist](https://tuist.dev) 4.x and Xcode 26+.

## How it stays deterministic (the in-process mock)

Every SDK network call goes through `URLSession.shared`, so in E2E mode the app
registers a `URLProtocol` ([`GalvaMockURLProtocol`](GalvaDemo/Sources/E2E/GalvaMockURLProtocol.swift))
that claims `*.galva.test` and replays canned fixtures for every endpoint
(init, poll, resolve, batchCollect, transactions, and the `<cdn>/<version>.html`
bundle). No server, no ports, no ATS exceptions — but the real download → disk
cache → WebView → bridge path still runs. The SDK is pointed at the mock via
`Galva.Environment.custom(...)`.

UI tests select a scenario through launch environment:

| `GALVA_E2E_SCENARIO` | Poll returns | Used by |
|---|---|---|
| `showInAppMessage` | one in-app message | in-app message + bridge tests |
| `deepLinkTarget` | nothing (deep link only) | deep-link + deferral tests |
| `noMessages` | nothing | identity/track upload tests |

`E2EBootstrap` wipes identity + caches on each launch so tests are independent.

## What's covered

- **In-app message display + bridge** — `getMessageData`, `getPageContext`,
  `apiFetch`, `showAlert`, `dismiss` ([InAppMessageUITests](GalvaDemoUITests/InAppMessageUITests.swift)).
- **Deep links** — `gvdemo://openCommunication?communicationId=…` rendering,
  and **deferral-until-identify** ([DeepLinkUITests](GalvaDemoUITests/DeepLinkUITests.swift)).
- **Identity + events** — `identify` / `track` actually upload, asserted
  against the recorded request bodies ([IdentityEventUITests](GalvaDemoUITests/IdentityEventUITests.swift)).

## Run by hand against the dev server

Launch without the E2E env and the app uses `Galva.Environment.development`.
Provide a key via the `GALVA_DEV_API_KEY` scheme environment variable, then
fire a deep link from the terminal:

```sh
xcrun simctl openurl booted "gvdemo://openCommunication?communicationId=<id>"
```

## Add a new flow

1. Add a button to [`ControlPanelView`](GalvaDemo/Sources/ControlPanelView.swift)
   with an `accessibilityIdentifier`.
2. Add any new fixture/route to [`MockFixtures`](GalvaDemo/Sources/E2E/MockFixtures.swift)
   / [`GalvaMockURLProtocol`](GalvaDemo/Sources/E2E/GalvaMockURLProtocol.swift).
3. Add a test under [`GalvaDemoUITests`](GalvaDemoUITests).
