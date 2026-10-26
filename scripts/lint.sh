#!/usr/bin/env bash
#
# scripts/lint.sh
#
# Galva SDK lint rules — canonical, dependency-free.
#
# Catches host-app perf hazards and quality regressions in Sources/,
# and checks the privacy manifest against the code (needs macOS for
# `plutil`). Runs in CI and locally. If SwiftLint is installed,
# `.swiftlint.yml` adds extra coverage on top of these rules; this
# script is the floor everyone must pass.
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

# Print one violation: the rule, what to do, then any offending lines.
report() {
    local rule_name="$1"
    local message="$2"
    local details="${3:-}"
    echo "${red}${bold}✗ $rule_name${reset}"
    echo "  ${message}"
    if [ -n "$details" ]; then
        echo "$details"
    fi
    echo ""
    violations=$((violations + 1))
}

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
        # Strip the SOURCES prefix so paths are repo-relative.
        report "$rule_name" "$message" "$(echo "$matches" | sed "s|^$SOURCES/|    Sources/|")"
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
# Tier 5 — privacy manifest. Galva is compiled into the host app, so
# App Store Connect rejects the host's upload for a manifest it can't
# read (ITMS-91056) or a required-reason API no manifest declares
# (ITMS-91053). Xcode builds both without a warning.
# -------------------------------------------------------------------

MANIFEST="Sources/Resources/PrivacyInfo.xcprivacy"

# Apple's values (developer.apple.com/documentation/bundleresources/
# app-privacy-configuration), without their common prefixes.
APPLE_DATA_TYPES="Name EmailAddress PhoneNumber PhysicalAddress OtherUserContactInfo
    Health Fitness PaymentInfo CreditInfo OtherFinancialInfo PreciseLocation
    CoarseLocation SensitiveInfo Contacts EmailsOrTextMessages PhotosorVideos
    AudioData GameplayContent CustomerSupport OtherUserContent BrowsingHistory
    SearchHistory UserID DeviceID PurchaseHistory ProductInteraction
    AdvertisingData OtherUsageData CrashData PerformanceData OtherDiagnosticData
    EnvironmentScanning Hands Head OtherDataTypes"
APPLE_PURPOSES="ThirdPartyAdvertising DeveloperAdvertising Analytics
    ProductPersonalization AppFunctionality Other"
APPLE_API_CATEGORIES="FileTimestamp SystemBootTime DiskSpace ActiveKeyboards UserDefaults"

# Apple's reasons for each required-reason API category.
api_reasons() {
    case "$1" in
        FileTimestamp)   echo "DDA9.1 C617.1 3B52.1 0A2A.1" ;;
        SystemBootTime)  echo "35F9.1 8FFB.1 3D61.1" ;;
        DiskSpace)       echo "85F4.1 E174.1 7D9E.1 B728.1" ;;
        ActiveKeyboards) echo "3EC4.1 54BD.1" ;;
        UserDefaults)    echo "CA92.1 1C8F.1 C56D.1 AC6B.1" ;;
    esac
}

# The Swift that reaches each category's APIs (Apple's list), as pairs
# of category and extended regex. `A|B`: either category covers it
# (getattrlist reads timestamps or disk space).
API_USES=(
    "SystemBootTime"          '\b(systemUptime|mach_absolute_time)\b'
    "UserDefaults"            '\b(NS)?UserDefaults\b|@AppStorage\b'
    "FileTimestamp"           '\.(creationDate|modificationDate|fileModificationDate)\b|\b(contentModificationDateKey|creationDateKey)\b|\b(stat|fstat|fstatat|lstat)\s*\('
    "DiskSpace"               '\bvolume(Available|Total)Capacity[A-Za-z]*Key\b|\.(systemFreeSize|systemSize)\b|\bf?statv?fs\s*\('
    "FileTimestamp|DiskSpace" '\bf?getattrlist(at|bulk)?\s*\('
    "ActiveKeyboards"         '\bactiveInputModes\b'
)

# Whether `value` is `prefix` followed by one of the words in `list`.
is_apple_value() {
    local prefix="$1" value="$2" list="$3"
    case "$value" in "$prefix"*) ;; *) return 1 ;; esac
    case " $(echo $list) " in *" ${value#"$prefix"} "*) return 0 ;; esac
    return 1
}

# The manifest's value at `keypath` if it's a `type` (bool, string,
# array, …), as plutil's raw text: an array prints its count. Fails if
# it's absent or another type.
manifest_value() {
    plutil -extract "$1" raw -expect "$2" -o - "$ROOT/$MANIFEST" 2>/dev/null
}

# Whether the manifest has a value at `keypath`.
manifest_has() {
    plutil -extract "$1" raw -o - "$ROOT/$MANIFEST" >/dev/null 2>&1
}

# Every line of Swift in Sources/ as `Sources/…:line:code`, comments
# removed (doc comments name APIs they don't call), `galva-lint:disable`
# lines left out. String literals stay: interpolations are code.
swift_code() {
    (cd "$ROOT" && find Sources -name '*.swift' -print0 | xargs -0 awk '
        FNR == 1 { block = 0; multiline = 0 }
        /galva-lint:disable/ { next }
        {
            code = ""; quoted = 0; i = 1; n = length($0)
            while (i <= n) {
                c = substr($0, i, 1); two = substr($0, i, 2); three = substr($0, i, 3)
                if (block) {
                    if (two == "/*") { block++; i += 2 }
                    else if (two == "*/") { block--; i += 2 }
                    else i++
                    continue
                }
                if (multiline) {
                    if (three == "\"\"\"") { multiline = 0; code = code three; i += 3; continue }
                } else if (quoted) {
                    if (c == "\\") { code = code two; i += 2; continue }
                    if (c == "\"") quoted = 0
                } else if (three == "\"\"\"") {
                    multiline = 1; code = code three; i += 3; continue
                } else if (c == "\"") {
                    quoted = 1
                } else if (two == "//") {
                    break
                } else if (two == "/*") {
                    block = 1; i += 2; continue
                }
                code = code c; i++
            }
            print FILENAME ":" FNR ":" code
        }')
}

# Apple's format: only its four keys, holding Apple's values, each
# reason under its own category. Prints what's wrong.
manifest_format_problems() {
    local key i j count type purposes purpose category reasons reason
    for key in $(plutil -convert xml1 -o - "$ROOT/$MANIFEST" | sed -nE $'s#^\t<key>(.*)</key>$#\\1#p'); do
        case "$key" in
            NSPrivacyTracking|NSPrivacyTrackingDomains|NSPrivacyCollectedDataTypes|NSPrivacyAccessedAPITypes) ;;
            *) echo "$key isn't a privacy manifest key" ;;
        esac
    done
    for key in NSPrivacyTrackingDomains NSPrivacyCollectedDataTypes NSPrivacyAccessedAPITypes; do
        if manifest_has "$key" && ! manifest_value "$key" array >/dev/null; then
            echo "$key must be an array"
        fi
    done

    count="$(manifest_value NSPrivacyCollectedDataTypes array)" || count=0
    i=0
    while [ "$i" -lt "$count" ]; do
        key="NSPrivacyCollectedDataTypes.$i"
        type="$(manifest_value "$key.NSPrivacyCollectedDataType" string)" || type=""
        if ! is_apple_value NSPrivacyCollectedDataType "$type" "$APPLE_DATA_TYPES"; then
            echo "$key: \"$type\" isn't one of Apple's data types"
        fi
        manifest_value "$key.NSPrivacyCollectedDataTypeLinked" bool >/dev/null \
            || echo "$key ($type): NSPrivacyCollectedDataTypeLinked must be a Boolean"
        manifest_value "$key.NSPrivacyCollectedDataTypeTracking" bool >/dev/null \
            || echo "$key ($type): NSPrivacyCollectedDataTypeTracking must be a Boolean"
        purposes="$(manifest_value "$key.NSPrivacyCollectedDataTypePurposes" array)" || purposes=0
        if [ "$purposes" -eq 0 ]; then
            echo "$key ($type): NSPrivacyCollectedDataTypePurposes must list at least one purpose"
        fi
        j=0
        while [ "$j" -lt "$purposes" ]; do
            purpose="$(manifest_value "$key.NSPrivacyCollectedDataTypePurposes.$j" string)" || purpose=""
            if ! is_apple_value NSPrivacyCollectedDataTypePurpose "$purpose" "$APPLE_PURPOSES"; then
                echo "$key ($type): \"$purpose\" isn't one of Apple's purposes"
            fi
            j=$((j + 1))
        done
        i=$((i + 1))
    done

    count="$(manifest_value NSPrivacyAccessedAPITypes array)" || count=0
    i=0
    while [ "$i" -lt "$count" ]; do
        key="NSPrivacyAccessedAPITypes.$i"
        category="$(manifest_value "$key.NSPrivacyAccessedAPIType" string)" || category=""
        if ! is_apple_value NSPrivacyAccessedAPICategory "$category" "$APPLE_API_CATEGORIES"; then
            echo "$key: \"$category\" isn't one of Apple's API categories"
        fi
        category="${category#NSPrivacyAccessedAPICategory}"
        reasons="$(manifest_value "$key.NSPrivacyAccessedAPITypeReasons" array)" || reasons=0
        if [ "$reasons" -eq 0 ]; then
            echo "$key ($category): NSPrivacyAccessedAPITypeReasons must list at least one reason"
        fi
        j=0
        while [ "$j" -lt "$reasons" ]; do
            reason="$(manifest_value "$key.NSPrivacyAccessedAPITypeReasons.$j" string)" || reason=""
            if ! is_apple_value "" "$reason" "$(api_reasons "$category")"; then
                echo "$key ($category): \"$reason\" isn't one of Apple's reasons for it"
            fi
            j=$((j + 1))
        done
        i=$((i + 1))
    done
}

# Whether the manifest lists required-reason API `category`.
declares_api() {
    local i count
    count="$(manifest_value NSPrivacyAccessedAPITypes array)" || count=0
    i=0
    while [ "$i" -lt "$count" ]; do
        if [ "$(manifest_value "NSPrivacyAccessedAPITypes.$i.NSPrivacyAccessedAPIType" string)" \
            = "NSPrivacyAccessedAPICategory$1" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

check_privacy_manifest() {
    local problems tracking i count code categories pattern uses category covered used=" "

    problems="$(manifest_format_problems)"
    if [ -n "$problems" ]; then
        report "privacy-manifest-format" \
            "$MANIFEST doesn't follow Apple's format, so App Store Connect can reject the host app (ITMS-91056)." \
            "$(echo "$problems" | sed 's/^/    /')"
    fi

    # TN3181: an SDK that doesn't track sets NSPrivacyTracking to false
    # and leaves out NSPrivacyTrackingDomains, even an empty one.
    if ! tracking="$(manifest_value NSPrivacyTracking bool)"; then
        report "privacy-manifest-tracking" "$MANIFEST must set NSPrivacyTracking to true or false."
    elif [ "$tracking" = "false" ]; then
        if manifest_has NSPrivacyTrackingDomains; then
            report "privacy-manifest-tracking" \
                "NSPrivacyTracking is false, so remove the NSPrivacyTrackingDomains key from $MANIFEST, even an empty one (Apple TN3181)."
        fi
        count="$(manifest_value NSPrivacyCollectedDataTypes array)" || count=0
        i=0
        while [ "$i" -lt "$count" ]; do
            if [ "$(manifest_value "NSPrivacyCollectedDataTypes.$i.NSPrivacyCollectedDataTypeTracking" bool)" != "false" ]; then
                report "privacy-manifest-tracking" \
                    "NSPrivacyTracking is false, so NSPrivacyCollectedDataTypes.$i must set NSPrivacyCollectedDataTypeTracking to false too."
            fi
            i=$((i + 1))
        done
    elif [ "$(manifest_value NSPrivacyTrackingDomains array || echo 0)" -eq 0 ]; then
        report "privacy-manifest-tracking" \
            "NSPrivacyTracking is true, so NSPrivacyTrackingDomains must list the domains that track (iOS blocks them until the user allows tracking)."
    fi

    # Every required-reason API the code calls is declared, and every
    # declared one is called.
    code="$(swift_code)"
    set -- "${API_USES[@]}"
    while [ "$#" -gt 0 ]; do
        categories="$1"
        pattern="$2"
        shift 2
        uses="$(printf '%s\n' "$code" | grep -E "$pattern" || true)"
        if [ -z "$uses" ]; then
            continue
        fi
        covered=""
        for category in $(echo "$categories" | tr '|' ' '); do
            used="$used$category "
            if declares_api "$category"; then
                covered="yes"
            fi
        done
        if [ -z "$covered" ]; then
            report "privacy-manifest-required-reason-api" \
                "Sources/ calls a required-reason API that $MANIFEST doesn't declare. Add NSPrivacyAccessedAPICategory$(echo "$categories" | sed 's/|/ or NSPrivacyAccessedAPICategory/g') with the reason that fits (Apple's NSPrivacyAccessedAPIType docs), or append // galva-lint:disable reason=\"…\" if the match isn't that API." \
                "$(echo "$uses" | sed 's/^/    /')"
        fi
    done

    count="$(manifest_value NSPrivacyAccessedAPITypes array)" || count=0
    i=0
    while [ "$i" -lt "$count" ]; do
        category="$(manifest_value "NSPrivacyAccessedAPITypes.$i.NSPrivacyAccessedAPIType" string)" || category=""
        category="${category#NSPrivacyAccessedAPICategory}"
        case "$used" in
            *" $category "*) ;;
            *)
                if [ -n "$(api_reasons "$category")" ]; then
                    report "privacy-manifest-unused-api" \
                        "$MANIFEST declares NSPrivacyAccessedAPICategory$category, but nothing in Sources/ calls its APIs. Remove the entry: the manifest must match what the SDK does."
                fi
                ;;
        esac
        i=$((i + 1))
    done
}

if ! command -v plutil >/dev/null 2>&1; then
    report "privacy-manifest" "plutil not found. The privacy-manifest checks run on macOS."
elif [ ! -f "$ROOT/$MANIFEST" ]; then
    report "privacy-manifest" "$MANIFEST is missing. Package.swift and cocoapods/galva-build.rb ship it to apps."
elif ! lint_output="$(plutil -lint "$ROOT/$MANIFEST" 2>&1)"; then
    report "privacy-manifest" \
        "plutil can't read $MANIFEST, so App Store Connect can't either (ITMS-91056)." \
        "    ${lint_output#"$ROOT/"}"
else
    check_privacy_manifest
fi

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
