//
//  NativeBridge+APIFetch.swift
//  Galva
//
//  `apiFetch` bridge method — proxy an HTTP request from the hosted page
//  through the SDK's APIClient (which owns the base URL and API key).
//
//  Surface:
//    • `handleAPIFetch(payload:)` — entry point dispatched from
//       `NativeBridge.handle(envelope:)` for the `.apiFetch` method.
//    • `ParsedAPIFetch`, `parseAPIFetch(_:)`, `encodeAPIResponse(_:)`,
//      `apiFetchAllowedMethods` — `static` / pure helpers exposed for
//      unit testing via `@testable import Galva`.
//
//  Add new HTTP-proxy behaviour (different durability modes, request
//  rewriting, etc.) here rather than touching the core bridge file.
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

    /// Proxy an HTTP request from the hosted page to the Galva API.
    ///
    /// Wire payload (only `path` is required):
    ///     {
    ///       "path":    "/identities/…/something",   // relative path
    ///       "method":  "POST",                       // default "GET"
    ///       "body":    { … } | "raw string",         // object → JSON body
    ///       "headers": { "Accept": "application/json" }
    ///     }
    ///
    /// The SDK prepends the API base URL, injects the API key (the bundle
    /// can neither see nor override it), and refuses any path that escapes
    /// the API origin.
    ///
    /// Resolves (fetch-style) for ANY completed round-trip — including
    /// 4xx / 5xx — with:
    ///     {
    ///       "status": 200, "ok": true,
    ///       "headers": { "content-type": "application/json", … },
    ///       "body": <parsed JSON | string>,
    ///       "bodyType": "json" | "text" | "base64"
    ///     }
    ///
    /// Rejects only on a malformed / disallowed path (`invalidPayload`) or a
    /// transport-layer failure (`apiRequestFailed`).
    func handleAPIFetch(
        payload: [String: AnyJSONValue]?
    ) async -> Result<AnyJSONValue?, BridgeError> {
        let parsed: ParsedAPIFetch
        switch Self.parseAPIFetch(payload) {
        case .success(let value): parsed = value
        case .failure(let error): return .failure(error)
        }
        logger.debug(.identity, "bridge apiFetch", metadata: [
            "method": parsed.method,
            "path": parsed.path,
            "shouldRetry": parsed.shouldRetry ? "true" : "false",
        ])

        // Fire-and-forget durable path: persist for guaranteed eventual
        // delivery (retries across network loss + app launches) and ack the
        // bundle immediately — it does NOT wait for the HTTP response.
        if parsed.shouldRetry {
            let queued = await messageManager.enqueueDurableProxyRequest(
                path: parsed.path,
                method: parsed.method,
                body: parsed.body,
                additionalHeaders: parsed.headers
            )
            guard queued else {
                return .failure(BridgeError(
                    code: .apiRequestFailed,
                    message: "Durable request queue unavailable"
                ))
            }
            return .success(.object(["queued": .bool(true)]))
        }

        do {
            let response = try await messageManager.apiProxyFetch(
                path: parsed.path,
                method: parsed.method,
                body: parsed.body,
                additionalHeaders: parsed.headers
            )
            // Encode the typed result straight to the wire `[String: AnyJSONValue]`
            // via the shared `toJSON` helper — same path `getPageContext` uses.
            return .success(.object(Self.toJSON(Self.encodeAPIResponse(response))))
        } catch let apiError as APIError {
            switch apiError {
            case .malformedURL:
                return .failure(BridgeError(
                    code: .invalidPayload,
                    message: "apiFetch path is invalid or targets a disallowed origin"
                ))
            default:
                return .failure(BridgeError(
                    code: .apiRequestFailed,
                    message: "apiFetch transport error: \(String(describing: apiError))"
                ))
            }
        } catch {
            return .failure(BridgeError(
                code: .apiRequestFailed,
                message: "apiFetch failed: \(String(describing: error))"
            ))
        }
    }

    /// Parsed + validated `apiFetch` request. Internal (not private) so the
    /// pure parse / encode logic can be unit-tested without a live WebView.
    struct ParsedAPIFetch: Equatable {
        let path: String
        let method: String
        let body: Data?
        let headers: [String: String]
        /// When `true`, the bundle is firing-and-forgetting: the SDK persists
        /// the request and guarantees eventual delivery (retries across
        /// network outages and app launches) rather than awaiting it inline.
        let shouldRetry: Bool
    }

    /// HTTP methods the bundle may proxy. Conservative allowlist — anything
    /// else is rejected as `invalidPayload`.
    static let apiFetchAllowedMethods: Set<String> =
        ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"]

    /// Decode the `apiFetch` payload into a validated request. Pure +
    /// static for testability.
    static func parseAPIFetch(
        _ payload: [String: AnyJSONValue]?
    ) -> Result<ParsedAPIFetch, BridgeError> {
        guard let payload,
              case .string(let path)? = payload["path"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "apiFetch requires a non-empty path"))
        }

        // Method — default GET, upper-cased, allowlisted.
        var method = "GET"
        if case .string(let raw)? = payload["method"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            method = raw.uppercased()
        }
        guard apiFetchAllowedMethods.contains(method) else {
            return .failure(BridgeError(code: .invalidPayload,
                                        message: "apiFetch method not allowed: \(method)"))
        }

        // Additional headers — string→string only; non-string values dropped.
        var headers: [String: String] = [:]
        if case .object(let object)? = payload["headers"] {
            for (key, value) in object {
                if case .string(let stringValue) = value { headers[key] = stringValue }
            }
        }

        // Body — a string is sent as raw UTF-8; an object / array / scalar is
        // JSON-encoded with a default Content-Type of application/json
        // (unless the caller already set one). Absent / null → no body.
        var body: Data?
        switch payload["body"] {
        case .none, .some(.null):
            body = nil
        case .some(.string(let stringBody)):
            body = Data(stringBody.utf8)
        case .some(let jsonBody):
            guard let encoded = try? JSONEncoder().encode(jsonBody) else {
                return .failure(BridgeError(code: .invalidPayload,
                                            message: "apiFetch body could not be encoded"))
            }
            body = encoded
            let hasContentType = headers.keys.contains {
                $0.caseInsensitiveCompare("Content-Type") == .orderedSame
            }
            if !hasContentType { headers["Content-Type"] = "application/json" }
        }

        // shouldRetry — opt-in durable, fire-and-forget delivery. Default false
        // (normal inline request the bundle awaits). Only an explicit `true`
        // boolean enables it.
        var shouldRetry = false
        if case .bool(let flag)? = payload["shouldRetry"] { shouldRetry = flag }

        return .success(ParsedAPIFetch(
            path: path, method: method, body: body, headers: headers, shouldRetry: shouldRetry
        ))
    }

    /// Map a raw `APIClient.ProxyResponse` into the typed `BridgeAPIFetchResult`.
    /// The body is decoded into a structured JSON value when the response
    /// advertises JSON (and actually parses), otherwise a UTF-8 string,
    /// otherwise base64 so binary payloads survive the trip. The typed result
    /// is what defines the wire shape — the caller encodes it via `toJSON`.
    /// Pure + static for testability.
    static func encodeAPIResponse(
        _ response: APIClient.ProxyResponse
    ) -> BridgeAPIFetchResult {
        let contentType = response.headers["content-type"]?.lowercased() ?? ""

        let body: AnyJSONValue
        let bodyType: BridgeAPIFetchResult.BodyType
        if !response.body.isEmpty,
           contentType.contains("json"),
           let decoded = try? JSONDecoder().decode(AnyJSONValue.self, from: response.body) {
            body = decoded
            bodyType = .json
        } else if let text = String(data: response.body, encoding: .utf8) {
            body = .string(text)
            bodyType = .text
        } else {
            body = .string(response.body.base64EncodedString())
            bodyType = .base64
        }

        return BridgeAPIFetchResult(
            status: response.status,
            ok: (200..<300).contains(response.status),
            headers: response.headers,
            body: body,
            bodyType: bodyType
        )
    }
}

#endif // canImport(WebKit) && canImport(UIKit)
