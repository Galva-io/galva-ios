//
//  InAppMessageWebViewFactory.swift
//  Galva
//
//  Builds the `WKWebView` + `NativeBridge` pair the in-app message
//  presentation needs. Shared by every host:
//      • UIKit `InAppMessagePresenter` (modal sheet via present(animated:))
//      • SwiftUI `InAppMessageSheetCoordinator` (sheet content view)
//
//  Encapsulating the build logic in one place keeps the two hosts in
//  lockstep — same `WKUserContentController` script handler, same
//  `window.galvaProducts` pre-injection, same security posture (no DOM
//  persistence, file:// allowlist).
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(StoreKit)
import StoreKit
#endif

#if canImport(WebKit) && canImport(UIKit)

@MainActor
enum InAppMessageWebViewFactory {

    /// Build a fresh `WKWebView` + `NativeBridge` for an in-app message.
    /// The caller mounts the WebView (UIKit sheet VC's view, SwiftUI
    /// `UIViewRepresentable`, …) and retains the bridge for the lifetime
    /// of the presentation. Note: `WKUserContentController.add(_:name:)`
    /// retains its script-message handler STRONGLY (a long-known WebKit
    /// gotcha) — every host MUST call `tearDown(webView:bridge:)` below on
    /// dismiss so the channel is severed promptly instead of waiting on
    /// the WebView dealloc cascade.
    ///
    /// On Apple platforms the optional `storeKitPrefetcher` lets the
    /// bridge's `requestPurchase` handler skip a live
    /// `Product.products(for:)` round-trip when the SKU is warm. The
    /// `#if canImport(StoreKit)` overload mirrors the same conditional
    /// on `NativeBridge.init` — non-Apple builds use the slimmer init.
    #if canImport(StoreKit)
    static func make(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        storeKitPrefetcher: StoreKitProductPrefetcher?,
        host: any InAppMessageHost,
        prefetchedProducts: [String: AnyJSONValue],
        deepLinkParameters: [String: String] = [:],
        logger: any GalvaLogger
    ) -> (WKWebView, NativeBridge) {
        let bridge = NativeBridge(
            messageManager: messageManager,
            identity: identity,
            storeKitPrefetcher: storeKitPrefetcher,
            logger: logger
        )
        return assemble(
            bridge: bridge,
            host: host,
            prefetchedProducts: prefetchedProducts,
            deepLinkParameters: deepLinkParameters
        )
    }
    #else
    static func make(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        host: any InAppMessageHost,
        prefetchedProducts: [String: AnyJSONValue],
        deepLinkParameters: [String: String] = [:],
        logger: any GalvaLogger
    ) -> (WKWebView, NativeBridge) {
        let bridge = NativeBridge(
            messageManager: messageManager,
            identity: identity,
            logger: logger
        )
        return assemble(
            bridge: bridge,
            host: host,
            prefetchedProducts: prefetchedProducts,
            deepLinkParameters: deepLinkParameters
        )
    }
    #endif

    /// Wire the bridge into a fresh `WKWebView`, install the
    /// `window.galvaProducts` user script, and apply our standard
    /// WebView config (no DOM persistence, inline media, transparent
    /// background). The bridge-init branching above feeds into this
    /// shared assembly.
    private static func assemble(
        bridge: NativeBridge,
        host: any InAppMessageHost,
        prefetchedProducts: [String: AnyJSONValue],
        deepLinkParameters: [String: String] = [:]
    ) -> (WKWebView, NativeBridge) {
        let config = WKWebViewConfiguration()
        bridge.host = host
        config.userContentController.add(bridge, name: kGalvaBridgeHandlerName)

        // Inject prefetched StoreKit products as `window.galvaProducts`
        // BEFORE any bundle script runs. The bundle reads the global
        // synchronously on boot — no bridge round-trip needed for pricing.
        // Callers pass structured `AnyJSONValue`s; serialization happens here,
        // at the single injection boundary.
        config.userContentController.addUserScript(
            makeGlobalInjectionScript(global: "galvaProducts", object: prefetchedProducts)
        )

        // When opened from a deep link, expose its query parameters as
        // `window.galvaDeepLinkParams` (e.g. `{ communicationId, … }`) so the
        // bundle can read them synchronously on boot. Empty `{}` for the
        // normal stream-driven presentation path. The flat string→string query
        // map is lifted to JSON string values for injection.
        config.userContentController.addUserScript(
            makeGlobalInjectionScript(
                global: "galvaDeepLinkParams",
                object: deepLinkParameters.mapValues(AnyJSONValue.string)
            )
        )

        // When debug logging is on, forward the WebView's console output (and
        // uncaught errors) to the SDK logger so integrators can debug the
        // bundle without attaching Safari Web Inspector. Gated on the log
        // level so production builds neither pay the per-call bridge hop nor
        // surface bundle internals over the channel.
        if bridge.logger.isEnabled(.debug) {
            let consoleHandler = WebViewConsoleLogHandler(logger: bridge.logger)
            config.userContentController.add(
                consoleHandler,
                name: WebViewConsoleLogHandler.handlerName
            )
            config.userContentController.addUserScript(makeConsoleForwardingScript())
            // `add(_:name:)` retains the handler strongly, so technically the
            // content controller already keeps it alive. We mirror it on the
            // bridge anyway so `tearDown(webView:bridge:)` has a single place
            // to drop the strong ref alongside the script-handler removal.
            bridge.consoleLogHandler = consoleHandler
        }

        // Inline media without user gesture for autoplay video components.
        // Bundle authors decide whether to use it.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // No DOM persistence — every message boots fresh. Avoids stale
        // localStorage poisoning future presentations.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return (webView, bridge)
    }

    /// Sever every native ↔ WebView edge so the WebView (and through it
    /// the bridge + console handler + bundled HTML) can release as soon
    /// as the host drops its strong refs. Mirror of `make(...)` / the
    /// `assemble` path above — every script handler / delegate it
    /// installs is undone here. Safe to call multiple times.
    ///
    /// Why this matters: `WKUserContentController.add(_:name:)` retains
    /// its handlers strongly, and a `WKWebView` waiting on an in-flight
    /// `evaluateJavaScript` (or a `loadFileURL` resource handle) can
    /// outlive the host's release of its strong ref by enough time to
    /// keep the entire HTML bundle paged in. Calling this on dismiss
    /// gives WebKit an immediate signal to wind those resources down.
    static func tearDown(webView: WKWebView, bridge: NativeBridge?) {
        // Cancel any in-flight bundle load so WebKit drops its load-side
        // completion blocks (which transitively retain the WebView).
        webView.stopLoading()
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: kGalvaBridgeHandlerName)
        controller.removeScriptMessageHandler(forName: WebViewConsoleLogHandler.handlerName)
        // Delegates are declared `weak` by WebKit so this isn't a cycle
        // break, but explicit clearing means a stray WebKit callback
        // arriving post-dismiss can't ping a half-torn-down VC.
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        // Drop the bridge's strong console-handler ref so the handler
        // releases even if the bridge is still pinned by an in-flight
        // dispatch Task with strong `self` inside an `await`.
        bridge?.consoleLogHandler = nil
        // Sever the bridge → host weak edge too — defensive, since the
        // host owns this teardown and is about to release the bridge,
        // but it prevents an in-flight bridge call from re-entering a
        // half-destructed host.
        bridge?.host = nil
    }

    /// Build a `.atDocumentStart` user script that assigns `object` (encoded
    /// to JSON here) to `window.<global>` before any bundle script runs:
    ///
    ///     window.galvaProducts = { … };
    ///
    /// Used for `galvaProducts` (StoreKit catalog) and `galvaDeepLinkParams`
    /// (deep-link query params). Encoding lives here — the single injection
    /// boundary — so callers pass structured `AnyJSONValue`s and can't supply
    /// an arbitrary, possibly-unsafe string. An empty map (or an encode
    /// failure, which can't happen for `AnyJSONValue`) yields `{}` so the
    /// bundle can always read the global without a `typeof` guard. JSON is a
    /// subset of JS, but we defensively escape U+2028 / U+2029, which are
    /// valid in JSON strings yet break out of inline JS source.
    private static func makeGlobalInjectionScript(
        global: String,
        object: [String: AnyJSONValue]
    ) -> WKUserScript {
        let json = encodeJSONObject(object)
        let sanitized = json
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return WKUserScript(
            source: "window.\(global) = \(sanitized);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    /// Encode a JSON object to a compact, key-sorted string. Returns `"{}"`
    /// for an empty map or the (unreachable for `AnyJSONValue`) encode failure.
    private static func encodeJSONObject(_ object: [String: AnyJSONValue]) -> String {
        guard !object.isEmpty else { return "{}" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// `WKUserScript` (main frame, document-start) that wraps the page's
    /// `console.*` methods to forward `{ level, message }` to the
    /// `galvaConsole` handler, then calls the originals so Safari Web
    /// Inspector output is unchanged. Also reports uncaught errors and
    /// unhandled promise rejections — the failures hardest to spot in a
    /// hosted bundle. The script is static (no interpolation), so there's
    /// nothing to escape.
    private static func makeConsoleForwardingScript() -> WKUserScript {
        let source = #"""
        (function () {
          var bridge = window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.galvaConsole;
          if (!bridge) { return; }
          function post(level, args) {
            try {
              var parts = [];
              for (var i = 0; i < args.length; i++) {
                var a = args[i];
                if (typeof a === 'string') { parts.push(a); }
                else {
                  try { parts.push(JSON.stringify(a)); }
                  catch (e) { parts.push(String(a)); }
                }
              }
              bridge.postMessage({ level: level, message: parts.join(' ') });
            } catch (e) { /* never let logging break the page */ }
          }
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
            var original = (typeof console[level] === 'function')
              ? console[level].bind(console)
              : function () {};
            console[level] = function () {
              post(level, arguments);
              original.apply(console, arguments);
            };
          });
          window.addEventListener('error', function (e) {
            post('error', [
              (e && e.message) || 'Script error',
              (e && e.filename) ? ('(' + e.filename + ':' + (e.lineno || 0) + ')') : ''
            ]);
          });
          window.addEventListener('unhandledrejection', function (e) {
            post('error', ['Unhandled promise rejection:', (e && e.reason) ? String(e.reason) : '']);
          });
        })();
        """#
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
