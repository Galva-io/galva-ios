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

    // MARK: - Request builder + perform

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: SDKConstants.rpcTimeout)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue(SDKConstants.sdkVersionHeader, forHTTPHeaderField: "x-sdk-version")
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
