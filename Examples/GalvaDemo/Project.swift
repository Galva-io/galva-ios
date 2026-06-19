import ProjectDescription

// Tuist manifest for the Galva SDK end-to-end demo + UI-test harness.
//
// The app links the local `Galva` SPM package straight from the repo root
// (../..), so it consumes the SDK exactly as a host app would via SwiftPM —
// no XCFramework, no vendored copy. Regenerate with `tuist generate` (the
// .xcodeproj / .xcworkspace are git-ignored).

let project = Project(
    name: "GalvaDemo",
    packages: [
        .local(path: "../..")
    ],
    targets: [
        .target(
            name: "GalvaDemo",
            destinations: .iOS,
            product: .app,
            bundleId: "io.galva.demo",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .extendingDefault(with: [
                "UILaunchScreen": [:],
                // Register the `gvdemo` URL scheme so the OS routes
                // `gvdemo://…` deep links to this app (Galva claims any
                // scheme beginning with `gv`).
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "io.galva.demo.deeplink",
                        "CFBundleURLSchemes": ["gvdemo"],
                    ]
                ],
            ]),
            sources: ["GalvaDemo/Sources/**"],
            resources: ["GalvaDemo/Resources/**"],
            dependencies: [
                .package(product: "Galva")
            ]
        ),
        .target(
            name: "GalvaDemoUITests",
            destinations: .iOS,
            product: .uiTests,
            bundleId: "io.galva.demo.uitests",
            deploymentTargets: .iOS("16.0"),
            infoPlist: .default,
            sources: ["GalvaDemoUITests/**"],
            dependencies: [
                .target(name: "GalvaDemo")
            ]
        ),
    ]
)
