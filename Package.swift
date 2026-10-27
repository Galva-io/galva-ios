// swift-tools-version: 6.2
//
// The oldest toolchain that can resolve this package, so the floor for
// every app that depends on it. 6.2 is Xcode 26, the oldest Xcode that
// compiles Galva: its StoreKit offer path uses an iOS 26 SDK API,
// back-deployed to iOS 15. With an older Xcode, SwiftPM stops at
// resolution, saying which tools version the package needs, instead of
// failing to compile Galva's sources.
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
