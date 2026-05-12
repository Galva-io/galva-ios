#!/usr/bin/env bash
#
# scripts/lint.sh
#
# Galva SDK lint rules — canonical, dependency-free.
#
# Catches host-app perf hazards and quality regressions in Sources/.
# Runs in CI and locally. If SwiftLint is installed, `.swiftlint.yml`
# adds extra coverage on top of these rules; this script is the floor
# everyone must pass.
#
# Run from anywhere:
#
#     ./scripts/lint.sh        # exits non-zero on any violation
#     ./scripts/lint.sh --fix  # reserved for future use
#
# Disabling a single line — append a same-line trailing comment with a
# reason. The reason is required so reviewers can audit each disable:
#
#     let foo = URL(string: someConstant)! // galva-lint:disable reason="provably valid"
#
# Disabling a whole rule for a file is intentionally NOT supported.
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES="$ROOT/Sources"

if [ ! -d "$SOURCES" ]; then
    echo "error: $SOURCES does not exist (run from inside the galva-ios repo)" >&2
    exit 2
fi

# Pretty-printer state.
violations=0
red=$(printf '\033[31m')
yellow=$(printf '\033[33m')
green=$(printf '\033[32m')
bold=$(printf '\033[1m')
reset=$(printf '\033[0m')

# Scan all .swift files in Sources/ for `pattern`. Skip lines tagged
# with `galva-lint:disable`. Report each match as `file:line: …`.
check() {
    local rule_name="$1"
    local pattern="$2"
    local message="$3"
    local matches
    matches="$(
        grep -rnE "$pattern" "$SOURCES" --include='*.swift' \
            | grep -v 'galva-lint:disable' \
            || true
    )"
    if [ -n "$matches" ]; then
        echo "${red}${bold}✗ $rule_name${reset}"
        echo "  ${message}"
        # Strip the SOURCES prefix so paths are repo-relative.
        echo "$matches" | sed "s|^$SOURCES/|    Sources/|"
        echo ""
        violations=$((violations + 1))
    fi
}

echo "${bold}Running Galva lint on Sources/${reset}"
echo ""

# -------------------------------------------------------------------
# Tier 1 — host-app perf hazards. These BLOCK the calling thread,
# which means they could affect the host app's UI or system perf.
# All errors, no exceptions.
# -------------------------------------------------------------------

check "no-dispatch-main-sync" \
    'DispatchQueue\.main\.sync' \
    "DispatchQueue.main.sync blocks the calling thread. Use \`await MainActor.run { ... }\` from an async context or \`Task { @MainActor in ... }\` for fire-and-forget."

check "no-thread-sleep" \
    '\bThread\.sleep\b' \
    "Thread.sleep blocks the calling thread (including GalvaActor). Use \`try await Task.sleep(nanoseconds:)\`."

check "no-dispatch-semaphore" \
    '\bDispatchSemaphore\b' \
    "DispatchSemaphore blocks the calling thread. Use actor isolation or async/await."

check "no-runloop-run-until" \
    'RunLoop\.[a-zA-Z]+\.run\s*\(\s*until' \
    "RunLoop.run(until:) blocks. Use Task-based async waiting."

check "no-sync-c-sleep" \
    '(^|[^a-zA-Z._])(usleep|nanosleep)\s*\(' \
    "usleep/nanosleep block the calling thread. Use \`try await Task.sleep(nanoseconds:)\`. (Thread.sleep is already covered by no-thread-sleep.)"

# -------------------------------------------------------------------
# Tier 2 — observability hazards. These bypass the configured logger
# pipeline so QA/developers can't see them in Console.app or forward
# them into their own logging system.
# -------------------------------------------------------------------

check "no-print" \
    '\b(print|debugPrint|NSLog)\s*\(' \
    "Use the logger (logger.debug/info/warning/error). print/debugPrint/NSLog write to stdout and bypass the GalvaLogger pipeline."

# -------------------------------------------------------------------
# Tier 3 — host-app crash hazards. Force unwraps/casts/tries crash
# the host app on failure. The SDK never crashes the host.
# -------------------------------------------------------------------

check "no-force-try" \
    '\btry!\s' \
    "try! crashes the host app on failure. Use do/catch or try?."

check "no-force-cast" \
    '\sas!\s' \
    "as! crashes the host app on type mismatch. Use \`as?\` with a guard or fallback."

# Force unwrap on common initializer patterns that take strings. These
# are the realistic places a crash slips in (a typo in a hardcoded URL,
# a UUID parsed from server data, etc.). The script's universal
# `galva-lint:disable` post-filter handles documented exceptions.
check "no-force-unwrap-init" \
    '\b(UUID|URL|Date|UserDefaults)\(.+\)!' \
    "Force-unwrapping a String-input initializer crashes the host on malformed input. Use a guard with \`else { ... }\`, or append // galva-lint:disable reason=\"...\" if the input is provably constant."

# -------------------------------------------------------------------
# Tier 4 — SDK consistency. Patterns we've decided to standardize on.
# -------------------------------------------------------------------

check "no-fatalerror-in-sources" \
    'fatalError\s*\(' \
    "fatalError crashes the host app. Replace with proper error handling or a log entry at .fault level. (preconditionFailure for true invariants only — and even those should be rare.)"

# -------------------------------------------------------------------
# Report
# -------------------------------------------------------------------

if [ "$violations" -eq 0 ]; then
    echo "${green}${bold}✓ Lint passed${reset} (0 violations)"
    exit 0
else
    echo "${red}${bold}✗ Lint failed${reset} — $violations rule(s) violated above."
    echo ""
    echo "To bypass a rule, append a same-line comment with a reason:"
    echo "  ${yellow}let foo = URL(...)! // galva-lint:disable reason=\"<why>\"${reset}"
    exit 1
fi
