//
//  NativeBridge+PageContext.swift
//  Galva
//
//  `getPageContext` bridge method — assemble the `BridgePageContext`
//  snapshot every hosted bundle reads on boot (SDK version, locale, push
//  authorization, App Store storefront, safe-area insets, app account
//  token, …).
//
//  Surface:
//    • `makePageContext(messageId:)` — entry point called from
//       `NativeBridge.handle(envelope:)` for the `.getPageContext` method.
//
//  Local helpers cover the individual fields (`appBundleInfo`,
//  `safeAreaInsets`, `currentPushAuthorization`, `currentStorefrontCountryCode`,
//  `mapAuthorization`). Add a new context field here when you extend
//  `BridgePageContext` rather than touching the core bridge file.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(WebKit) && canImport(UIKit)

extension NativeBridge {

    /// Build the `BridgePageContext` snapshot for the active message.
    /// Called once per `.getPageContext` bridge call.
    func makePageContext(messageId: String) async -> BridgePageContext {
        let safe = safeAreaInsets()
        let pushAuth = await currentPushAuthorization()
        let app = appBundleInfo()
        let storefrontCode = await currentStorefrontCountryCode()
        // Same UUID the SDK attaches to Galva-initiated StoreKit purchases —
        // override from identify(userId:appAccountToken:) or the anonymousId
        // as a UUID. Hand it to the bundle so its own purchase/attribution
        // calls reconcile to the same account.
        let appAccountToken = await identity.purchaseAttributionToken
        return BridgePageContext(
            messageId: messageId,
            sessionToken: nil, // signed token attaches in a follow-up; bundle reads as-nil-safe
            bridgeProtocol: SDKConstants.bridgeProtocolVersion,
            sdkVersion: SDKConstants.version,
            platform: "ios",
            appVersion: app.version,
            appBuild: app.build,
            pushAuthorization: pushAuth,
            locale: Locale.current.identifier,
            appColorScheme: nil, // SDK doesn't override; bundle falls back to matchMedia
            safeArea: safe,
            storefrontCountryCode: storefrontCode,
            appAccountToken: appAccountToken.uuidString.lowercased()
        )
    }

    /// ISO 3166-1 alpha-3 storefront code (`"USA"`, `"GBR"`, `"JPN"`,
    /// etc.) from `StoreKit.Storefront.current`. Returns `nil` when
    /// StoreKit isn't reachable (Simulator without StoreKit config,
    /// device hasn't signed into the App Store, sandbox issues). The
    /// bundle uses this to pick storefront-specific copy without an
    /// extra bridge round-trip.
    private func currentStorefrontCountryCode() async -> String? {
        #if canImport(StoreKit)
        return await Storefront.current?.countryCode
        #else
        return nil
        #endif
    }

    private func appBundleInfo() -> (version: String?, build: String?) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String,
                info["CFBundleVersion"] as? String)
    }

    private func safeAreaInsets() -> BridgePageContext.SafeArea {
        // Delegate to the host — each host computes insets from whichever
        // view it owns (UIKit VC's view, or the SwiftUI sheet's hosting
        // view). The insets reflect the *presented sheet's* safe area,
        // which is what the bundle needs to pad against (grabber +
        // dynamic island + home indicator), NOT the under-sheet host
        // window's insets.
        let insets = host?.safeAreaInsets ?? .zero
        return .init(
            top: Double(insets.top),
            bottom: Double(insets.bottom),
            left: Double(insets.left),
            right: Double(insets.right)
        )
    }

    private func currentPushAuthorization() async -> BridgePageContext.PushAuthorization {
        await withCheckedContinuation { (cont: CheckedContinuation<BridgePageContext.PushAuthorization, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: Self.mapAuthorization(settings.authorizationStatus))
            }
        }
    }

    /// Pure enum mapper — called from the `UNUserNotificationCenter`
    /// completion handler, which is `@Sendable` and nonisolated. Marking
    /// the function `nonisolated` drops the `@MainActor` inheritance the
    /// surrounding class would otherwise impose, so the call site
    /// doesn't need an isolation hop.
    nonisolated private static func mapAuthorization(
        _ status: UNAuthorizationStatus
    ) -> BridgePageContext.PushAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .authorized:    return .authorized
        case .provisional:   return .provisional
        case .ephemeral:     return .ephemeral
        @unknown default:    return .notDetermined
        }
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
