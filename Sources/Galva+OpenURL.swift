//
//  Galva+OpenURL.swift
//  Galva
//
//  Deep-link forwarders for UIKit App / Scene delegates. A `gv://` link can
//  reach an app through three delegate methods, and the URL lives in a
//  different container in each. Rather than make the host app dig it out,
//  these mirror the delegate signatures 1:1 — drop
//  `Galva.<sameMethod>(<same args>)` into the delegate method and you're
//  done. Every variant funnels into
//  `Galva.handleOpenURL(_:)`, so routing + the deferral-until-identify
//  behavior are identical regardless of which entry point delivered the URL.
//
//      | When               | Delegate method                          |
//      | ------------------ | ---------------------------------------- |
//      | warm (no scenes)   | application(_:open:options:)              |
//      | cold (no scenes)   | application(_:open:options:)              |
//      | cold (scenes)      | scene(_:willConnectTo:options:)           |
//      | warm (scenes)      | scene(_:openURLContexts:)                 |
//
//  SwiftUI-lifecycle apps don't need any of this — they forward from
//  `.onOpenURL { url in Galva.handleOpenURL(url) }`, which fires for both cold
//  and warm. Only custom `gv://` schemes are claimed; `http(s)` / universal
//  links return `false`.
//

import Foundation

#if canImport(UIKit)
import UIKit

public extension Galva {

    /// Forward from `UIApplicationDelegate.application(_:open:options:)`
    /// (non-scene apps). UIKit calls it for the launch URL too, so this one
    /// forwarder covers both cold and warm opens.
    ///
    ///     func application(_ app: UIApplication, open url: URL,
    ///                      options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    ///         Galva.application(app, open: url, options: options)
    ///     }
    ///
    /// - Returns: `true` if Galva claimed the URL (so you can `return` it, or
    ///   fall through to your own router when `false`).
    @discardableResult
    @MainActor
    static func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        handleOpenURL(url)
    }

    /// Forward from `UISceneDelegate.scene(_:willConnectTo:options:)` to catch
    /// a **cold-launch** URL on scene-based apps (the URLs arrive in
    /// `connectionOptions.urlContexts`).
    ///
    ///     func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
    ///                options connectionOptions: UIScene.ConnectionOptions) {
    ///         Galva.scene(scene, willConnectTo: session, options: connectionOptions)
    ///     }
    @discardableResult
    @MainActor
    static func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) -> Bool {
        handleOpenURLs(connectionOptions.urlContexts.map { $0.url })
    }

    /// Forward from `UISceneDelegate.scene(_:openURLContexts:)` (warm open,
    /// scene-based apps).
    ///
    ///     func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    ///         Galva.scene(scene, openURLContexts: URLContexts)
    ///     }
    @discardableResult
    @MainActor
    static func scene(
        _ scene: UIScene,
        openURLContexts URLContexts: Set<UIOpenURLContext>
    ) -> Bool {
        handleOpenURLs(URLContexts.map { $0.url })
    }
}

#endif // canImport(UIKit)
