//
//  Uploader.swift
//  Galva
//
//  HTTP transport for Galva's batch-collect endpoint.
//
//  Wire:
//    POST https://api.galva.dev/identities/batchCollect
//    Headers: X-API-Key, x-sdk-version, Content-Type: application/json
//    Body:    { "messages": [ … 1..100 … ], "sentAt": ISO8601 }
//
//  Outcome classification (drives queue behaviour):
//    2xx                          → .success     (batch deleted)
//    408, 429                     → .retryable   (backoff + retry)
//    5xx                          → .retryable
//    4xx (other than 408/429)     → .permanent   (logged, dropped)
//    transport (network/timeout)  → .retryable
//    encoding (malformed batch)   → .permanent   (rare; bug in SDK)
//
//  Why 4xx is permanent: malformed payloads or wrong API keys won't fix
//  themselves on retry, and retrying forever would wedge the queue.
//

import Foundation

/// Outcome the queue uses to decide whether to delete the batch.
enum UploadOutcome: @unchecked Sendable {
    case success
    case retryable(Error)
    case permanent(Error)
}

enum UploadError: Error, @unchecked Sendable {
    case http(status: Int, body: String?)
    case transport(Error)
    case encoding(Error)
    case invalidResponse
    case cancelled
}

actor Uploader {
    let baseURL: URL
    let apiKey: String
    let session: URLSession
    let logger: any GalvaLogger
    private let encoder: JSONEncoder

    init(baseURL: URL, apiKey: String, session: URLSession = .shared, logger: any GalvaLogger) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.logger = logger

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        self.encoder = enc
    }

    /// Upload a single batch. Caller (queue) decides what to do based on outcome.
    func upload(messages: [Message]) async -> UploadOutcome {
        guard !messages.isEmpty else { return .success }
        let url = baseURL.appendingPathComponent(SDKConstants.batchCollectPath)

        let request: URLRequest
        do {
            request = try makeRequest(url: url, messages: messages)
        } catch {
            logger.log(.error, message: "Uploader: failed to encode batch", error: error)
            // Encoding failure is permanent — message can't be sent regardless.
            return .permanent(UploadError.encoding(error))
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .retryable(UploadError.invalidResponse)
            }
            return classify(status: http.statusCode, body: data)
        } catch {
            // URLSession transport error — almost always retryable (network down,
            // timeout, DNS, TLS, etc.). Cancellation propagates as retryable too.
            if (error as NSError).code == NSURLErrorCancelled {
                return .retryable(UploadError.cancelled)
            }
            return .retryable(UploadError.transport(error))
        }
    }

    // MARK: - Request builder

    private func makeRequest(url: URL, messages: [Message]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue(SDKConstants.sdkVersionHeader, forHTTPHeaderField: "x-sdk-version")
        let body = BatchCollectRequest(messages: messages, sentAt: Date())
        req.httpBody = try encoder.encode(body)
        return req
    }

    // MARK: - Status classification

    private func classify(status: Int, body: Data) -> UploadOutcome {
        switch status {
        case 200..<300:
            return .success
        case 408, 429:
            return .retryable(UploadError.http(status: status, body: bodyString(body)))
        case 500..<600:
            return .retryable(UploadError.http(status: status, body: bodyString(body)))
        case 400..<500:
            // 4xx (other than 408/429) is a client error — payload is invalid,
            // auth is wrong, etc. Retrying won't help. Quarantine the batch.
            return .permanent(UploadError.http(status: status, body: bodyString(body)))
        default:
            return .retryable(UploadError.http(status: status, body: bodyString(body)))
        }
    }

    private func bodyString(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Backoff helper

enum Backoff {
    /// Exponential backoff with full jitter. Capped at 60s.
    /// attempt 0 → 0s (immediate)
    /// attempt 1 → up to 2s
    /// attempt 2 → up to 4s
    /// …
    /// attempt 6+ → up to 60s
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let base = min(60.0, pow(2.0, Double(attempt)))
        return Double.random(in: 0...base)
    }
}
