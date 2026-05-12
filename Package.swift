// swift-tools-version: 6.0
//
// Minimum Swift the package manifest needs to parse. Bumping this also
// bumps the floor for *consumers* (anyone resolving us via SPM must have
// at least this toolchain). The source code uses Swift 6 strict-
// concurrency features but nothing 6.2-specific, so 6.0 is the right
// floor — broader Xcode 16.x coverage in CI and downstream apps.
import PackageDescription

let package = Package(
    name: "Galva",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        // Default product for SPM source consumers — static linking,
        // zero dynamic-load overhead at app launch.
        .library(
            name: "Galva",
            targets: ["Galva"]
        ),

        // Dynamic variant used ONLY by `scripts/build-xcframework.sh`
        // to produce the prebuilt `Galva.xcframework`. SPM consumers
        // never pick this product (the default name "Galva" wins). The
        // `_dynamic` suffix is a marker, not part of the public API.
        .library(
            name: "Galva_dynamic",
            type: .dynamic,
            targets: ["Galva"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Galva",
            path: "Sources",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "GalvaTests",
            dependencies: ["Galva"],
            path: "Tests"
        ),
    ]
)
