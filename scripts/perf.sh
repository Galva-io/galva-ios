#!/usr/bin/env bash
#
# scripts/perf.sh
#
# Run the performance E2E suite: launches the demo app WITH the SDK and
# WITHOUT (baseline), measures resident memory / launch / CPU, and writes a
# before/after report to Examples/GalvaDemo/perf-report.md. Exits non-zero if
# a gating budget is breached (the memory delta) — immediate CI notification.
#
# Usage:
#     ./scripts/perf.sh
#     GALVA_E2E_DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro' ./scripts/perf.sh
#
# Requires: Tuist 4.x and Xcode 26+.
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO="$ROOT/Examples/GalvaDemo"
REPORT="$DEMO/perf-report.md"

if ! command -v tuist >/dev/null 2>&1; then
    echo "error: tuist not found on PATH. Install it: https://tuist.dev" >&2
    exit 2
fi

if [ -n "${GALVA_E2E_DESTINATION:-}" ]; then
    DESTINATION="$GALVA_E2E_DESTINATION"
else
    UDID="$(xcrun simctl list devices available \
        | grep -E 'iPhone' \
        | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
        | head -1)"
    if [ -z "$UDID" ]; then
        echo "error: no available iPhone simulator found" >&2
        exit 2
    fi
    DESTINATION="platform=iOS Simulator,id=$UDID"
fi

echo "==> Generating project (tuist generate)"
tuist generate --path "$DEMO" --no-open

echo "==> Running performance suite on: $DESTINATION"
RESULT_BUNDLE="$DEMO/.perf-result.xcresult"
rm -rf "$RESULT_BUNDLE"

LOG="$(mktemp)"
set +e
xcodebuild test \
    -workspace "$DEMO/GalvaDemo.xcworkspace" \
    -scheme GalvaDemo \
    -destination "$DESTINATION" \
    -only-testing:GalvaDemoUITests/PerformanceUITests \
    -resultBundlePath "$RESULT_BUNDLE" | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e

# Extract the before/after report the test printed between sentinel markers.
if grep -q 'GALVA-PERF-REPORT-BEGIN' "$LOG"; then
    sed -n '/===GALVA-PERF-REPORT-BEGIN===/,/===GALVA-PERF-REPORT-END===/p' "$LOG" \
        | sed '1d;$d' > "$REPORT"
    echo ""
    echo "==> Wrote $REPORT"
    echo "----------------------------------------"
    cat "$REPORT"
    echo "----------------------------------------"
else
    echo "warning: no perf report markers found in test output" >&2
fi

rm -f "$LOG"
exit "$STATUS"
