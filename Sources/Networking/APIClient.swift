//
//  APIClient.swift
//  Galva
//
//  Tiny typed JSON-over-HTTP client for non-batch RPC calls:
//      • POST /sdk/initialize
//      • GET  /identities/communications
//      • POST /identities/communications/{id}/resolve
//      • GET  https://webview.galva.io/<version>.html  (bundle download)
//
//  Separate from `Uploader` because:
//      • The batch uploader is a single-purpose actor optimized for the hot
//        identify/track/alias path. Pulling RPC calls into it would muddy
//        the contract and complicate retry semantics.
//      • RPC calls have caller-visible Codable responses; the batch endpoint
//        only cares about the HTTP outcome.
//
//  Retry policy:
//      The client does NOT retry on its own — calls return a typed Result and
//      let the caller decide. Initialization falls back to disk cache instead
//      of looping; the in-app message poller is driven by the foreground
//      lifecycle, so a fresh attempt rides the next event naturally.
//

import Foundation

actor APIClient {
    let baseURL: URL
    let apiKey: String
    let session: URLSession
    let logger: any GalvaLogger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared,
        logger: any GalvaLogger
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.logger = logger

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = ISO8601DateFormatter.galva.date(from: s) { return date }
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Invalid ISO 8601 date: \(s)"
            )
        }
        self.decoder = dec
    }

    // MARK: - GET / POST helpers

    /// Issue a JSON-bodied POST to `path`, decoding the response as `Response`.
    func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        responseType: Response.Type = Response.self
    ) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var req = makeRequest(url: url, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        return try await perform(req, responseType: Response.self)
    }

    /// Issue a GET with optional query items, decoding the response as `Response`.
    func get<Response: Decodable>(
        path: String,
        query: [URLQueryItem] = [],
        responseType: Response.Type = Response.self
    ) async throws -> Response {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw APIError.malformedURL(path) }
        let req = makeRequest(url: url, method: "GET")
        return try await perform(req, responseType: Response.self)
    }

    /// Download the raw bytes at `url` (no auth headers, no base URL). Used
    /// for fetching versioned HTML bundles from the S3-fronted CDN.
    func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: SDKConstants.rpcTimeout)
        req.httpMethod = "GET"
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode, body: data)
            }
            return data
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    // MARK: - Generic proxy (WebView `apiFetch` bridge)

    /// Raw HTTP outcome of `proxyRequest`. Unlike `get` / `post`, a non-2xx
    /// status is NOT an error here — it's returned verbatim so the in-app
    /// message WebView can read `status` + `body` and do its own handling
    /// (fetch-style). Only validation / transport failures throw.
    struct ProxyResponse: Sendable, Hashable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    /// Proxy an arbitrary request from the in-app message WebView to the
    /// Galva API. The hosted page supplies only a relative `path`; the SDK
    /// resolves it against `baseURL`, injects the API key, and refuses any
    /// path that would escape the API origin. That same-origin guard is the
    /// security boundary — the bundle can reach our API and nothing else.
    ///
    /// - Parameters:
    ///   - path: Relative path (`/x/y`, `x/y`, optionally with `?query`).
    ///           Absolute or scheme-relative URLs are rejected.
    ///   - method: HTTP method, already validated / upper-cased by the caller.
    ///   - body: Pre-serialized request body, or `nil`.
    ///   - additionalHeaders: Caller-supplied headers. Applied first; the
    ///           SDK-managed auth / version headers are set last so the
    ///           bundle can never spoof or override them.
    func proxyRequest(
        path: String,
        method: String,
        body: Data?,
        additionalHeaders: [String: String]
    ) async throws -> ProxyResponse {
        guard let url = Self.resolveProxyURL(path: path, base: baseURL) else {
            throw APIError.malformedURL(path)
        }
        var req = URLRequest(url: url, timeoutInterval: SDKConstants.rpcTimeout)
        req.httpMethod = method
        // Drop any caller attempt to set a reserved header — case-insensitive,
        // so a lowercase `x-api-key` can't slip a second auth header past the
        // override below. Then set the SDK-managed headers ourselves: the
        // bundle must never be able to spoof auth or version.
        let reserved: Set<String> = ["x-api-key", "x-sdk-version"]
        for (key, value) in additionalHeaders where !reserved.contains(key.lowercased()) {
            req.setValue(value, forHTTPHeaderField: key)
        }
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue(SDKIdentity.header, forHTTPHeaderField: "x-sdk-version")
        req.httpBody = body

        logger.debug(.uploader, "proxy \(method)", metadata: ["url": url.absoluteString])
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            var headers: [String: String] = [:]
            headers.reserveCapacity(http.allHeaderFields.count)
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key.lowercased()] = value
                }
            }
            // Log every completed proxy round-trip (success OR non-2xx). The
            // bridge surfaces non-2xx to the bundle as `ok:false` rather than
            // throwing, so the SDK trace is the only place to see the status.
            logger.debug(.uploader, "proxy result", metadata: [
                "status": String(http.statusCode),
                "url": url.absoluteString,
            ])
            return ProxyResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }

    /// Resolve a bundle-supplied relative `path` against the API `base`,
    /// returning `nil` when the result would target a different origin.
    /// Blocks SSRF: absolute URLs (`https://evil.com`), scheme-relative
    /// references (`//evil.com`), and anything whose resolved
    /// scheme / host / port doesn't match `base`.
    static func resolveProxyURL(path: String, base: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Contract is "relative path only" — reject absolute and
        // scheme-relative references outright.
        guard !trimmed.contains("://"), !trimmed.hasPrefix("//") else { return nil }
        // Normalize to an absolute-path reference so it replaces base's path
        // rather than resolving relative to base's last path segment.
        let reference = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard let resolved = URL(string: reference, relativeTo: base)?.absoluteURL else {
            return nil
        }
        // Defense in depth: the resolved request must still target the API
        // origin. A leading-slash reference can't change host today, but
        // keeping the check local makes the guarantee auditable.
        guard resolved.scheme == base.scheme,
              resolved.host == base.host,
              resolved.port == base.port else {
            return nil
        }
        return resolved
    }

    // MARK: - Request builder + perform

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: SDKConstants.rpcTimeout)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue(SDKIdentity.header, forHTTPHeaderField: "x-sdk-version")
        return req
    }

    private func perform<Response: Decodable>(
        _ req: URLRequest,
        responseType: Response.Type
    ) async throws -> Response {
        logger.debug(.uploader, "rpc \(req.httpMethod ?? "?")", metadata: [
            "url": req.url?.absoluteString ?? "<nil>",
        ])
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                logger.warning(.uploader, "rpc non-2xx", metadata: [
                    "status": String(http.statusCode),
                    "url": req.url?.absoluteString ?? "<nil>",
                ])
                throw APIError.http(status: http.statusCode, body: data)
            }
            // Symmetric "request OK" log so the request/response pair is
            // visible end-to-end at .debug — the start log alone leaves a
            // dangling trace if you're checking whether a response ever came.
            logger.debug(.uploader, "rpc OK", metadata: [
                "status": String(http.statusCode),
                "url": req.url?.absoluteString ?? "<nil>",
            ])
            do {
                return try decoder.decode(Response.self, from: data)
            } catch {
                throw APIError.decoding(error)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.transport(error)
        }
    }
}

// MARK: - Errors

enum APIError: Error, @unchecked Sendable {
    case malformedURL(String)
    case invalidResponse
    case http(status: Int, body: Data)
    case transport(Error)
    case decoding(Error)
}

extension APIError {
    /// True for errors where a future retry might succeed. Used by callers
    /// that want to bias toward fresh data — initialization, for instance,
    /// retains the disk cache only on retryable failures.
    var isRetryable: Bool {
        switch self {
        case .malformedURL, .decoding:
            return false
        case .invalidResponse, .transport:
            return true
        case .http(let status, _):
            // 408/429/5xx → transient. 4xx → bad request / auth → permanent.
            return status == 408 || status == 429 || (500..<600).contains(status)
        }
    }
}
