//
//  DeepLink+OpenCommunication.swift
//  Galva
//
//  Handler for the `openCommunication` deep-link route:
//
//      gv<scheme>://openCommunication?communicationId=<id>&<extra…>
//
//  It reuses the in-app message presentation flow — the same resolve →
//  download bundle → present WebView path as `message.show(in:)` — but takes
//  the communication id from the URL instead of the message stream. Every
//  query parameter on the URL is forwarded to the bundle as
//  `window.galvaDeepLinkParams`.
//
//  Routing lives in `SDKCore.handleOpenURL(_:)`, which parses the URL into a
//  typed `DeepLink` and calls this handler with the route's already-validated
//  parameters. This file is the template for adding more routes — drop a
//  `DeepLink+<Route>.swift` with an `extension SDKCore` handler, add a case to
//  `DeepLink`, and a branch to the router.
//

import Foundation

extension SDKCore {

    /// Handle `gv…://openCommunication?communicationId=…`. `communicationId`
    /// has already been validated non-empty by `DeepLink.parse(_:)`. Resolves
    /// that communication and presents it in the in-app message WebView on the
    /// app's foreground scene. All URL query parameters (`parameters`) are
    /// injected into the bundle as `window.galvaDeepLinkParams`.
    func handleOpenCommunication(communicationId: String, parameters: [String: String]) async {
        #if canImport(UIKit) && canImport(WebKit)
        // Minimal envelope — only `id` is used by resolve + present; the other
        // fields are display / dedupe metadata the deep-link path doesn't have.
        let message = InAppMessages.Message(
            id: communicationId,
            workflowType: nil,
            createdAt: Date(),
            rawType: "deeplink"
        )
        logger.info(.lifecycle, "openCommunication — presenting", metadata: [
            "communicationId": communicationId,
        ])
        do {
            // `scene: nil` → the presenter resolves the foreground window scene
            // on the main actor, so no non-Sendable UIWindowScene crosses here.
            // The query parameters cross as a Sendable `[String: String]`; the
            // factory serializes them into `window.galvaDeepLinkParams`.
            try await showInAppMessage(message, deepLinkParameters: parameters)
        } catch {
            logger.warning(.lifecycle, "openCommunication — presentation failed", metadata: [
                "communicationId": communicationId,
            ], error: error)
        }
        #else
        logger.warning(.lifecycle, "openCommunication — unsupported on this platform")
        #endif
    }
}
