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
            return try JSONDecoder().decode(InitializationData.self, from: data)
        } catch {
            return nil
        }
    }

    /// Persist the latest response. Errors are returned so the caller can
    /// log them — failure to cache isn't fatal (next launch re-fetches).
    func save(_ data: InitializationData) throws {
        let encoded = try JSONEncoder().encode(data)
        // Write atomically so a process kill mid-write can't leave a
        // truncated cache that load() would silently accept.
        try encoded.write(to: fileURL, options: [.atomic])
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
}
