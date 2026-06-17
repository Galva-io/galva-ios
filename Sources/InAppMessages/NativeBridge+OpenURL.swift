//
//  NativeBridge+OpenURL.swift
//  Galva
//
//  `openManageSubscription` and `openDeepLink` bridge methods — both
//  amount to "hand a `URL` to `UIApplication.open`," differing only in
//  the wire log tag and a small amount of dispatch glue.
//
//  Surface:
//    • `openURL(from:key:logTag:)` — entry point called from
//       `NativeBridge.handle(envelope:)` for both methods, parameterized
//       by the payload key and the log tag.
//
//  Add a new "open a URL" surface (e.g. `openInSafari`, `openWebPage`)
//  here rather than touching the core bridge file.
//

import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(UIKit)
import UIKit
#endif

#if canImport(WebKit) && canImport(UIKit)

extension NativeBridge {

    /// Resolve a `URL` from `payload[key]`, validate it with
    /// `UIApplication.canOpenURL`, and call `UIApplication.open`. The
    /// completion handler logs success / failure at debug / warning
    /// severity — the bundle's Promise resolves synchronously with
    /// `.bool(true)` as soon as we hand the URL off (matching the
    /// "fire-and-forget" semantics of the legacy bridge).
    func openURL(
        from payload: [String: AnyJSONValue]?,
        key: String,
        logTag: String
    ) -> Result<AnyJSONValue?, BridgeError> {
        guard let payload,
              case .string(let raw)? = payload[key],
              let url = URL(string: raw) else {
            return .failure(BridgeError(code: .invalidPayload, message: "Missing or malformed URL"))
        }
        let app = UIApplication.shared
        guard app.canOpenURL(url) else {
            logger.warning(.identity, "bridge \(logTag): URL not openable", metadata: ["url": raw])
            return .failure(BridgeError(code: .urlOpenFailed, message: "URL cannot be opened"))
        }
        app.open(url, options: [:]) { [weak self] success in
            // UIApplication.open(_:options:completionHandler:) calls back
            // on the main thread per UIKit contract — safe to touch self.
            MainActor.assumeIsolated {
                if success {
                    self?.logger.debug(.identity, "bridge \(logTag) opened", metadata: ["url": raw])
                } else {
                    self?.logger.warning(.identity, "bridge \(logTag) failed", metadata: ["url": raw])
                }
            }
        }
        return .success(.bool(true))
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
