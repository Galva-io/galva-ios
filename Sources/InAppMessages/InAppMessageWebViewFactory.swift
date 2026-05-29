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
    /// of the presentation — `WKUserContentController.add(_:name:)` only
    /// holds a weak reference to script-message handlers.
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
        prefetchedProductsJSON: String,
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
            prefetchedProductsJSON: prefetchedProductsJSON
        )
    }
    #else
    static func make(
        messageManager: InAppMessageManager,
        identity: IdentityStore,
        host: any InAppMessageHost,
        prefetchedProductsJSON: String,
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
            prefetchedProductsJSON: prefetchedProductsJSON
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
        prefetchedProductsJSON: String
    ) -> (WKWebView, NativeBridge) {
        let config = WKWebViewConfiguration()
        bridge.host = host
        config.userContentController.add(bridge, name: kGalvaBridgeHandlerName)

        // Inject prefetched StoreKit products as `window.galvaProducts`
        // BEFORE any bundle script runs. The bundle reads the global
        // synchronously on boot — no bridge round-trip needed for pricing.
        config.userContentController.addUserScript(
            makeProductsInjectionScript(json: prefetchedProductsJSON)
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
            // `add(_:name:)` only weakly retains the handler — park it on the
            // bridge (which the host retains strongly) so it lives as long as
            // the WebView.
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

    /// Build a `WKUserScript` that assigns the prefetched StoreKit
    /// product summary to `window.galvaProducts` at the very first
    /// chance (`.atDocumentStart`). The injected source is:
    ///
    ///     window.galvaProducts = { … };
    ///
    /// Falls back to an empty object literal when nothing has been
    /// pre-fetched so the bundle can always read `window.galvaProducts`
    /// without a `typeof` guard.
    private static func makeProductsInjectionScript(json: String) -> WKUserScript {
        let safe = json.isEmpty ? "{}" : json
        // The JSON we pass came from JSONSerialization and is therefore
        // safe to splice as a JavaScript object literal — JSON is a
        // subset of JS. We still defensively replace U+2028 / U+2029
        // since those characters are valid in JSON strings but break out
        // of inline JS source.
        let sanitized = safe
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let source = "window.galvaProducts = \(sanitized);"
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
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
