//
//  SDKIdentity.swift
//  Galva
//
//  The SDK's reported identity — library name + version — as sent in the
//  `x-sdk-version` header, the `context.library` field, and the `sdk_version`
//  event. Defaults to the native core (`ios` / `SDKConstants.version`).
//
//  A first-party wrapper SDK (React Native, Flutter, …) overrides it through the
//  internal `Galva.configure(…, wrapper:)` seam so its traffic is distinguishable
//  on the backend instead of masquerading as the native iOS SDK. The wrapper
//  reports, e.g., `react-native-ios/<rn-sdk-version>`; the native core version
//  stays available via `Galva.sdkVersion`. This is deliberately NOT part of the
//  public native API — wrappers reach it by compiling in the same Swift module.
//

import Foundation

/// Identity of a first-party wrapper SDK embedding the Galva iOS core (React
/// Native, Flutter, …). Internal — set through the internal
/// `Galva.configure(…, wrapper:)` seam, which wrappers reach by compiling in the
/// same Swift module. Not part of the public native API.
struct SDKWrapper: Sendable {
    /// Library name, e.g. `"react-native-ios"`.
    let name: String
    /// Wrapper SDK version, e.g. `"1.0.0"`.
    let version: String

    init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

enum SDKIdentity {
    /// Wrapper override, set once at `configure(...)` before any request goes
    /// out. `nonisolated(unsafe)`: written a single time during configure and
    /// only read afterward (the same set-once pattern as the lifecycle observer).
    nonisolated(unsafe) static var wrapper: SDKWrapper?

    /// Library name for `context.library` (e.g. `ios`, `react-native-ios`).
    static var libraryName: String { wrapper?.name ?? SDKConstants.libraryName }

    /// Reported SDK version — the wrapper's version when wrapped, else the core's.
    static var version: String { wrapper?.version ?? SDKConstants.version }

    /// Value for the `x-sdk-version` header. Format: `<library>/<version>`.
    static var header: String { "\(libraryName)/\(version)" }
}
