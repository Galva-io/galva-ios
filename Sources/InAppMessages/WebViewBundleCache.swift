//
//  WebViewBundleCache.swift
//  Galva
//
//  Resolves a `webviewVersion` string to a local `file://` URL that
//  WKWebView can `loadFileURL` against.
//
//  • Cache location: <Caches>/galva/webview/<version>.html
//    Application Support is the right home for "we cannot rebuild this"
//    state; bundles are content-addressed by an immutable version, so
//    Caches is correct — the OS may evict them under disk pressure and
//    we just re-download on next encounter.
//  • Bundles are immutable per version (the server uploads to a new
//    version key for every change), so once on disk a bundle never
//    needs revalidation.
//  • Concurrent requests for the same version coalesce — only one HTTP
//    request runs at a time per version, additional callers await the
//    same Task.
//  • LRU eviction is intentionally NOT implemented in v1. Bundles are
//    tiny (kB range), and Caches is OS-evictable; if we ever ship rich-
//    media bundles, a size-cap pass goes here.
//

import Foundation

/// Async, coalescing bundle cache. Lifetime owned by SDKCore.
actor WebViewBundleCache {

    private let directoryURL: URL
    private let client: APIClient
    private let cdnBaseURL: URL
    private let logger: any GalvaLogger

    /// In-flight downloads keyed by version. Allows two concurrent
    /// `bundleURL(for:)` callers for the same version to share one request.
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(
        directoryURL: URL? = nil,
        client: APIClient,
        cdnBaseURL: URL,
        logger: any GalvaLogger
    ) throws {
        self.client = client
        self.cdnBaseURL = cdnBaseURL
        self.logger = logger
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            self.directoryURL = try Self.defaultDirectory()
        }
        try Self.ensureDirectory(self.directoryURL)
    }

    // MARK: - Public API

    /// Resolve a version to a local file URL. Hits the cache first;
    /// downloads from the CDN on miss. Throws if the version cannot be
    /// downloaded AND is not already cached.
    func bundleURL(for version: String) async throws -> URL {
        let candidate = cachedURL(for: version)
        if FileManager.default.fileExists(atPath: candidate.path) {
            logger.debug(.configuration, "bundle cache hit", metadata: ["version": version])
            return candidate
        }
        return try await download(version: version)
    }

    /// Fire-and-forget pre-fetch. Used by the message manager to warm the
    /// cache for newly-received `webviewVersion`s so a subsequent
    /// `show(in:)` doesn't block on network. Errors are swallowed —
    /// nothing observably bad happens if the warm-up loses a race with
    /// the device going offline.
    func prefetch(version: String) {
        let candidate = cachedURL(for: version)
        if FileManager.default.fileExists(atPath: candidate.path) { return }
        Task { try? await download(version: version) }
    }

    /// Tests only — drop every cached bundle.
    func clear() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directoryURL.path) {
            try fm.removeItem(at: directoryURL)
        }
        try Self.ensureDirectory(directoryURL)
        inFlight.removeAll()
    }

    /// Tests / diagnostics — whether a given version is on disk right now.
    func isCached(_ version: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: version).path)
    }

    // MARK: - Internals

    private func download(version: String) async throws -> URL {
        if let task = inFlight[version] {
            // Another caller is already downloading this version. Await
            // the same task so we don't issue duplicate requests or write
            // to the same file in parallel.
            return try await task.value
        }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw APIError.transport(CancellationError()) }
            return try await self.performDownload(version: version)
        }
        inFlight[version] = task
        defer { inFlight[version] = nil }

        return try await task.value
    }

    private func performDownload(version: String) async throws -> URL {
        let remote = SDKConstants.webviewBundleURL(version: version, cdn: cdnBaseURL)
        logger.info(.configuration, "downloading bundle", metadata: [
            "version": version,
            "url": remote.absoluteString,
        ])
        let data = try await client.download(remote)
        let destination = cachedURL(for: version)
        // Atomic write so a kill mid-download can't leave a half-written
        // file that the next launch would happily load and crash on.
        try data.write(to: destination, options: [.atomic])
        logger.info(.configuration, "bundle persisted", metadata: [
            "version": version,
            "bytes": String(data.count),
        ])
        return destination
    }

    private func cachedURL(for version: String) -> URL {
        directoryURL.appendingPathComponent("\(version).html")
    }

    // MARK: - Directory helpers

    private static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches.appendingPathComponent("galva/webview", isDirectory: true)
    }

    private static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
