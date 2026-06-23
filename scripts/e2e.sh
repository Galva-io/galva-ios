#!/usr/bin/env bash
#
# scripts/e2e.sh
#
# Generate the Tuist demo project and run the end-to-end XCUITest suite on an
# iOS simulator. The tests drive a real host app that links the Galva SPM
# package and exercise the full stack (configure → poll → resolve → bundle →
# WebView → bridge → deep link) against an in-process mock — deterministic,
# no network.
#
# Usage:
#     ./scripts/e2e.sh
#     GALVA_E2E_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro' ./scripts/e2e.sh
#
# Requires: Tuist 4.x (https://tuist.dev) and Xcode 26+.
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/Examples/GalvaDemo"

if ! command -v tuist >/dev/null 2>&1; then
    echo "error: tuist not found on PATH. Install it: https://tuist.dev" >&2
    exit 2
fi

# Destination: honour an explicit override, else auto-pick the first available
# iPhone simulator by UDID. Name-based matching ("name=iPhone 16") is brittle —
# it varies by installed runtime — so we resolve a concrete UDID instead.
if [ -n "${GALVA_E2E_DESTINATION:-}" ]; then
    DESTINATION="$GALVA_E2E_DESTINATION"
else
    UDID="$(xcrun simctl list devices available \
        | grep -E 'iPhone' \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1)"
    if [ -z "$UDID" ]; then
        echo "error: no available iPhone simulator found (xcrun simctl list devices available)" >&2
        exit 2
    fi
    DESTINATION="platform=iOS Simulator,id=$UDID"
fi

echo "==> Generating project (tuist generate)"
tuist generate --path "$DEMO" --no-open

echo "==> Running E2E UI tests on: $DESTINATION"
RESULT_BUNDLE="$DEMO/.e2e-result.xcresult"
rm -rf "$RESULT_BUNDLE"

# `-retry-tests-on-failure -test-iterations 2` gives each test one retry (only
# failed tests re-run; passing tests run once). XCUITest interactions — WebView
# hit-testing, sheet dismiss animations, a11y snapshot timing — are inherently
# flaky on contended CI runners. A transient first-attempt flake shouldn't red
# the build, but a genuine regression still fails both attempts.
xcodebuild test \
    -workspace "$DEMO/GalvaDemo.xcworkspace" \
    -scheme GalvaDemo \
    -destination "$DESTINATION" \
    -skip-testing:GalvaDemoUITests/PerformanceUITests \
    -retry-tests-on-failure \
    -test-iterations 2 \
    -resultBundlePath "$RESULT_BUNDLE"
