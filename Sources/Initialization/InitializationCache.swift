//
//  InitializationCache.swift
//  Galva
//
//  On-disk cache for /sdk/initialize responses.
//
//  Why we cache: /sdk/initialize is called on every cold start and is the
//  load-bearing piece for in-app messaging (it carries the live webview-
//  bundle version list and the server-tuned batch flush window). If the
//  device is offline at launch, we still want a sensible last-known-good
//  payload to work from.
//
//  Storage location: Application Support / Galva / init.json. Application
//  Support is the documented home for app-private state, and the parent
//  directory is marked `isExcludedFromBackup` (matching the message queue's
//  reasoning) so the SDK never bloats iCloud backups.
//

import Foundation

/// Lightweight reader/writer for the cached /sdk/initialize response.
/// Synchronous because the payload is small (kB-range) and only touched on
/// SDK init + when the live response lands.
struct InitializationCache: Sendable {

    /// Absolute path to the cache file. Resolved once at construction so
    /// tests can override the location.
    let fileURL: URL

    /// Use the default Application Support / Galva / init.json location.
    /// Throws only if the parent directory can't be created — caller falls
    /// back to in-memory operation.
    init() throws {
        self.fileURL = try Self.defaultFileURL()
    }

    /// Construct with an explicit file location (tests).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Load / Save

    /// Read the persisted response. Returns `nil` if no cache exists yet,
    /// or if the cached payload can't be decoded against the current
    /// `InitializationData` schema (e.g. a stale build wrote a now-removed
    /// field — we'd rather hit the network than try to massage it).
    func load() -> InitializationData? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.makeDecoder().decode(InitializationData.self, from: data)
        } catch {
            return nil
        }
    }

    /// Persist the latest response. Errors are returned so the caller can
    /// log them — failure to cache isn't fatal (next launch re-fetches).
    func save(_ data: InitializationData) throws {
        let encoded = try Self.makeEncoder().encode(data)
        // Write atomically so a process kill mid-write can't leave a
        // truncated cache that load() would silently accept.
        try encoded.write(to: fileURL, options: [.atomic])
    }

    /// Remove the cache file. Used by tests; production never deletes the
    /// cache (we always prefer a stale read over no read).
    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: Path

    private static func defaultFileURL() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Galva", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var dirCopy = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dirCopy.setResourceValues(values)
        return dir.appendingPathComponent("init.json")
    }

    // MARK: Codecs
    //
    // Encoder/decoder built per call rather than stored as static lets:
    // (1) Swift 6 strict concurrency flags non-Sendable closures captured
    //     by global state, and (2) this path is hit at most twice per
    //     SDK launch (load + save), so the per-call cost is invisible.

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601DateFormatter.galva.string(from: date))
        }
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
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
        return d
    }
}
