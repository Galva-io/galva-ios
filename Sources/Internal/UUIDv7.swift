//
//  UUIDv7.swift
//  Galva
//
//  RFC 9562 UUID v7 generator — time-ordered UUIDs.
//
//  Why v7 (not Foundation's v4): the Galva server uses messageId as an
//  index key. Time-ordered UUIDs cluster contemporaneous events in the
//  index, dramatically improving write throughput vs random v4.
//
//  Layout (128 bits, big-endian):
//    bits  0–47   unix_ts_ms     ← millisecond timestamp
//    bits 48–51   version (0111) ← 4-bit version field = 7
//    bits 52–63   rand_a         ← 12 bits random
//    bits 64–65   variant (10)   ← 2-bit RFC 4122 variant
//    bits 66–127  rand_b         ← 62 bits random
//
//  Thread-safe. Uses `SystemRandomNumberGenerator` (cryptographically secure).
//

import Foundation

public enum UUIDv7 {
    /// Generate a new UUID v7. Thread-safe.
    public static func next() -> UUID {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48 bits unix_ts_ms
        bytes[0] = UInt8((nowMs >> 40) & 0xFF)
        bytes[1] = UInt8((nowMs >> 32) & 0xFF)
        bytes[2] = UInt8((nowMs >> 24) & 0xFF)
        bytes[3] = UInt8((nowMs >> 16) & 0xFF)
        bytes[4] = UInt8((nowMs >>  8) & 0xFF)
        bytes[5] = UInt8( nowMs        & 0xFF)

        // 74 bits random across bytes 6..15
        var random = [UInt8](repeating: 0, count: 10)
        random.withUnsafeMutableBytes { ptr in
            _ = SystemRandomNumberGenerator.fillBytes(into: ptr)
        }
        for i in 0..<10 { bytes[6 + i] = random[i] }

        // Version: top 4 bits of byte 6 = 0111
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        // Variant: top 2 bits of byte 8 = 10
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Random helper (Swift std)

private extension SystemRandomNumberGenerator {
    /// Fills the provided buffer with cryptographically secure random bytes.
    static func fillBytes(into buffer: UnsafeMutableRawBufferPointer) -> Int {
        var rng = SystemRandomNumberGenerator()
        var written = 0
        while written < buffer.count {
            let chunk = rng.next()
            let remaining = buffer.count - written
            let toCopy = Swift.min(remaining, MemoryLayout<UInt64>.size)
            withUnsafeBytes(of: chunk) { src in
                for i in 0..<toCopy {
                    buffer[written + i] = src[i]
                }
            }
            written += toCopy
        }
        return written
    }
}
