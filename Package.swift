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
        // The one and only product. Galva is distributed exclusively via
        // Swift Package Manager — no prebuilt XCFramework, no separate
        // dynamic variant. Linking (static vs dynamic) is left to SPM /
        // the consuming target so there's a single, unambiguous `Galva`.
        .library(
            name: "Galva",
            targets: ["Galva"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Galva",
            path: "Sources",
            // The privacy manifest: the data the SDK collects and its two
            // required-reason APIs, UserDefaults (CA92.1) and system boot
            // time (35F9.1), so apps don't declare them for Galva. Xcode
            // folds it into the app's privacy report. Copying the one file
            // puts it at the resource bundle's root. Never `.copy("Resources")`:
            // that nests it, and iOS code signing rejects the bundle.
            // scripts/lint.sh checks the manifest against Sources/.
            resources: [
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
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
