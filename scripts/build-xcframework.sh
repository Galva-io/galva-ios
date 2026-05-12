#!/usr/bin/env bash
#
# scripts/build-xcframework.sh
#
# Produces a prebuilt Galva.xcframework + zip for binary distribution.
#
# Outputs:
#   build/Galva.xcframework           ← drag-and-drop into an Xcode project
#   build/Galva.xcframework.zip       ← upload to GitHub Releases
#   build/Galva.xcframework.zip.checksum
#       ← paste into Package.swift's `.binaryTarget(...)` if you publish
#         a binary-SPM distribution
#
# Usage:
#   ./scripts/build-xcframework.sh
#
# Requirements:
#   • Xcode 15+ (xcodebuild understands SPM packages directly)
#   • Apple Silicon or Intel Mac
#
# Slices produced:
#   • iOS device         (arm64)
#   • iOS simulator      (arm64 + x86_64)
#
# To add macOS / Mac Catalyst / watchOS slices later, copy the two
# `xcodebuild archive` blocks and add a `-destination` line for the new
# platform, then list each new archive's framework in the
# `create-xcframework` step.
#

set -eu
# Deliberately NOT `pipefail`: piping xcodebuild output through `head`/
# `grep` is fine even if the producer gets SIGPIPE when the consumer
# closes its end. We assert on individual command outcomes explicitly.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
# Use the `_dynamic` SPM product (declared in Package.swift) — xcodebuild
# archives this as a framework, where the default static product would
# only produce a .o file.
SCHEME="Galva_dynamic"

# Tooling preflight ----------------------------------------------------
if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "error: xcodebuild not found — install Xcode + command-line tools" >&2
    exit 2
fi

xc_version=$(xcodebuild -version | head -1 | awk '{print $2}')
echo "→ using Xcode $xc_version"

# Wipe + recreate build dir.
rm -rf "$BUILD"
mkdir -p "$BUILD"

# Per-archive shared flags ---------------------------------------------
# SKIP_INSTALL=NO                        keep the built framework in the
#                                        archive (default would discard it)
# BUILD_LIBRARY_FOR_DISTRIBUTION=YES     emit stable swiftinterface so
#                                        consumers compiling with a newer
#                                        Swift version can still link
# OTHER_SWIFT_FLAGS=                     workaround for a Swift compiler
#   -no-verify-emitted-module-interface  bug: when a module name (Galva)
#                                        collides with a top-level public
#                                        type name (also `Galva`), the
#                                        swiftinterface verifier produces
#                                        spurious "is not a member type"
#                                        errors against its own output.
#                                        The .swiftinterface itself is
#                                        consumable; only the verifier
#                                        false-positives.
SHARED_FLAGS=(
    SKIP_INSTALL=NO
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES
    OTHER_SWIFT_FLAGS=-no-verify-emitted-module-interface
)

archive_slice() {
    local destination="$1"
    local archive_path="$2"
    echo "→ archiving: $destination"
    xcodebuild archive \
        -scheme "$SCHEME" \
        -destination "$destination" \
        -archivePath "$archive_path" \
        -derivedDataPath "$BUILD/DerivedData" \
        -configuration Release \
        "${SHARED_FLAGS[@]}" \
        | grep -E "^(error:|warning:|ARCHIVE)" || true
}

archive_slice "generic/platform=iOS"           "$BUILD/Galva-iOS"
archive_slice "generic/platform=iOS Simulator" "$BUILD/Galva-iOS-Simulator"

# Locate the built framework inside each archive. The SPM product is
# named `Galva_dynamic` (per Package.swift) so xcodebuild produces
# `Galva_dynamic.framework`; we rename the wrapper to `Galva.framework`
# for distribution — the underlying binary (which symbols are linked
# against) stays in place under the new bundle name.
rename_to_galva_framework() {
    local archive="$1"
    local original
    original=$(find "$archive" -name "Galva_dynamic.framework" -type d 2>/dev/null | head -1)
    if [ -z "$original" ]; then
        echo "error: could not locate Galva_dynamic.framework inside $archive" >&2
        exit 3
    fi

    local parent
    parent=$(dirname "$original")
    local renamed="$parent/Galva.framework"

    # Move the bundle, then rename the executable inside, then fix the
    # Info.plist's CFBundleExecutable + CFBundleName.
    mv "$original" "$renamed"
    if [ -f "$renamed/Galva_dynamic" ]; then
        mv "$renamed/Galva_dynamic" "$renamed/Galva"
        # The dylib's install name still references "Galva_dynamic" —
        # patch it so consumers loading the framework find the right
        # binary name at runtime.
        install_name_tool -id \
            "@rpath/Galva.framework/Galva" \
            "$renamed/Galva" 2>/dev/null || true
    fi
    if [ -f "$renamed/Info.plist" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Galva" "$renamed/Info.plist" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c "Set :CFBundleName Galva"       "$renamed/Info.plist" 2>/dev/null || true
    fi
    # The Swift module directory is also named after the dynamic product —
    # rename it so `import Galva` resolves in the XCFramework consumer.
    if [ -d "$renamed/Modules/Galva_dynamic.swiftmodule" ]; then
        mv "$renamed/Modules/Galva_dynamic.swiftmodule" "$renamed/Modules/Galva.swiftmodule"
    fi

    echo "$renamed"
}

DEVICE_FW=$(rename_to_galva_framework "$BUILD/Galva-iOS.xcarchive")
SIM_FW=$(rename_to_galva_framework "$BUILD/Galva-iOS-Simulator.xcarchive")

# Assemble the XCFramework --------------------------------------------
echo "→ assembling XCFramework"
xcodebuild -create-xcframework \
    -framework "$DEVICE_FW" \
    -framework "$SIM_FW" \
    -output "$BUILD/Galva.xcframework"

# Zip for distribution ------------------------------------------------
echo "→ zipping"
(cd "$BUILD" && zip -r -X -q Galva.xcframework.zip Galva.xcframework)

# SPM binary-target checksum ------------------------------------------
# swift package compute-checksum runs against the zip and prints the
# checksum required by `.binaryTarget(url:checksum:)` consumers.
echo "→ computing SPM binary-target checksum"
checksum=$(swift package compute-checksum "$BUILD/Galva.xcframework.zip")
echo "$checksum" > "$BUILD/Galva.xcframework.zip.checksum"

# Summary --------------------------------------------------------------
green=$(printf '\033[32m')
bold=$(printf '\033[1m')
reset=$(printf '\033[0m')
echo ""
echo "${green}${bold}✓ XCFramework built${reset}"
echo "  binary:   $BUILD/Galva.xcframework"
echo "  archive:  $BUILD/Galva.xcframework.zip"
echo "  checksum: $checksum"
echo ""
echo "Next steps:"
echo "  1. Test the .xcframework in a real consumer app."
echo "  2. Upload Galva.xcframework.zip to the GitHub release for this tag."
echo "  3. If publishing a binary-SPM variant, paste the checksum into"
echo "     the consumer Package.swift's .binaryTarget(checksum:) line."
