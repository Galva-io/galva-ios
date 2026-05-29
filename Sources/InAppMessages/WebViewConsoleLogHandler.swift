//
//  WebViewConsoleLogHandler.swift
//  Galva
//
//  Forwards the in-app message WebView's JavaScript console output to the
//  SDK logger so integrators can debug the hosted bundle from Xcode /
//  Console.app without attaching Safari Web Inspector.
//
//  Wiring (see `InAppMessageWebViewFactory`):
//      • A `WKUserScript` injected at `.atDocumentStart` wraps the page's
//        `console.log/info/warn/error/debug` (plus `window` error +
//        unhandledrejection) to post `{ level, message }` to the
//        `galvaConsole` script-message handler — then calls the originals,
//        so Web Inspector output is unchanged.
//      • This handler receives those messages and re-emits them through the
//        SDK logger, mapping the JS level onto a `Galva.LogLevel` so a
//        `console.error` surfaces as an error.
//
//  Only installed when debug logging is enabled. Gating at the WebView-build
//  site (not here) means production builds never pay the per-call bridge hop
//  and never surface bundle internals over the channel.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif

#if canImport(WebKit)

@MainActor
final class WebViewConsoleLogHandler: NSObject, WKScriptMessageHandler {

    /// Handler name registered on `WKUserContentController`, reached from JS
    /// as `webkit.messageHandlers.galvaConsole.postMessage(...)`. Distinct
    /// from the `galva` request/response bridge channel.
    static let handlerName = "galvaConsole"

    private let logger: any GalvaLogger

    init(logger: any GalvaLogger) {
        self.logger = logger
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName else { return }
        let entry = Self.parse(message.body)
        let line = "[webview] console.\(entry.level): \(entry.text)"
        // Re-emit at the mapped severity (a `console.error` shows up as an
        // error, etc.). All paths are >= .debug, which is enabled whenever
        // this handler is installed.
        switch Self.mapLevel(entry.level) {
        case .error, .fault: logger.error(.identity, line)
        case .warning:       logger.warning(.identity, line)
        case .notice:        logger.notice(.identity, line)
        case .info:          logger.info(.identity, line)
        case .debug, .off:   logger.debug(.identity, line)
        }
    }

    // MARK: - Pure helpers (testable)

    /// Extract `(level, text)` from the script-message body. The JS shim
    /// posts `{ level: String, message: String }`; tolerate a bare string or
    /// any other shape by stringifying so a malformed post still logs
    /// something useful.
    nonisolated static func parse(_ body: Any) -> (level: String, text: String) {
        if let dict = body as? [String: Any] {
            let level = (dict["level"] as? String) ?? "log"
            let text = (dict["message"] as? String) ?? ""
            return (level, text)
        }
        if let string = body as? String { return ("log", string) }
        return ("log", String(describing: body))
    }

    /// Map a JS console level onto a `Galva.LogLevel`. Unknown levels fall
    /// back to `.debug`.
    nonisolated static func mapLevel(_ jsLevel: String) -> Galva.LogLevel {
        switch jsLevel {
        case "error":        return .error
        case "warn":         return .warning
        case "info":         return .info
        case "debug", "log": return .debug
        default:             return .debug
        }
    }
}

#endif // canImport(WebKit)
