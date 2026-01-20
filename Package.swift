// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Galva",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
    ],
    products: [
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
