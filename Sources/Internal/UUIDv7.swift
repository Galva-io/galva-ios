//
//  UUIDv7.swift
//  Galva
//
//  RFC 9562 UUID v7 generator — time-ordered UUIDs with sub-millisecond
//  monotonicity (Section 6.2, "Method 1: Fixed-Length Dedicated Counter").
//
//  Why v7 (not Foundation's v4): the Galva server uses messageId as an
//  index key. Time-ordered UUIDs cluster contemporaneous events in the
//  index, dramatically improving write throughput vs random v4. The queue
//  also relies on UUID ordering matching emit order (FIFO).
//
//  Layout (128 bits, big-endian):
//    bits  0–47   unix_ts_ms     ← millisecond timestamp
//    bits 48–51   version (0111) ← 4-bit version field = 7
//    bits 52–63   seq            ← 12-bit monotonic counter (RFC §6.2)
//    bits 64–65   variant (10)   ← 2-bit RFC 4122 variant
//    bits 66–127  rand_b         ← 62 bits CSPRNG-derived
//
//  Monotonicity guarantees:
//    • Same-millisecond calls → counter increments → output sorts in call
//      order.
//    • Counter overflow (>0xFFF in one ms) → carries into the next ms.
//    • Clock rewinds (NTP, manual time-shift) → timestamp pins to the
//      previously-emitted ms until wall-clock catches up.
//
//  Thread-safe. `SystemRandomNumberGenerator` is cryptographically secure.
//
//  Testability:
//    • `MonotonicCounter` is internal so tests can instantiate fresh
//      instances (avoiding shared-state contamination) and verify
//      sequencing behaviour against a synthetic clock feed.
//    • `makeBytes(millis:sequence:randomBytes:)` is internal so tests can
//      assert the bit layout deterministically without rolling random bytes.
//

import Foundation

enum UUIDv7 {

    /// Generate a new UUID v7. Thread-safe and monotonically increasing.
    static func next() -> UUID {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let (millis, seq) = MonotonicCounter.shared.advance(currentMs: nowMs)

        // 62 bits of CSPRNG-derived randomness for rand_b (bytes 8..15).
        // Bytes 6 and 7 carry the version + 12-bit sequence.
        var randB = [UInt8](repeating: 0, count: 8)
        randB.withUnsafeMutableBytes { ptr in
            _ = SystemRandomNumberGenerator.fillBytes(into: ptr)
        }

        return makeBytes(millis: millis, sequence: seq, randomBytes: randB)
    }

    /// Pure bit-packer. Useful from tests to assert layout with a known
    /// `randomBytes` payload; production callers use `next()`.
    ///
    /// - Parameters:
    ///   - millis: 48-bit unix-ms timestamp (only the low 48 bits are used).
    ///   - sequence: 12-bit monotonic counter (only the low 12 bits are used).
    ///   - randomBytes: exactly 8 bytes used as `rand_b`. The variant bits
    ///     are stamped on by this function — the caller does not need to.
    static func makeBytes(
        millis: UInt64,
        sequence: UInt16,
        randomBytes: [UInt8]
    ) -> UUID {
        precondition(randomBytes.count == 8, "rand_b must be exactly 8 bytes")
        var bytes = [UInt8](repeating: 0, count: 16)

        // 48 bits unix_ts_ms (big-endian, bytes 0..5).
        bytes[0] = UInt8((millis >> 40) & 0xFF)
        bytes[1] = UInt8((millis >> 32) & 0xFF)
        bytes[2] = UInt8((millis >> 24) & 0xFF)
        bytes[3] = UInt8((millis >> 16) & 0xFF)
        bytes[4] = UInt8((millis >>  8) & 0xFF)
        bytes[5] = UInt8( millis        & 0xFF)

        // Version 0x7 in top nibble of byte 6, top 4 bits of seq in low nibble.
        bytes[6] = 0x70 | UInt8((sequence >> 8) & 0x0F)
        // Low 8 bits of seq.
        bytes[7] = UInt8(sequence & 0xFF)

        // rand_b across bytes 8..15.
        for i in 0..<8 { bytes[8 + i] = randomBytes[i] }
        // Variant (top 2 bits of byte 8 = 10xx).
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Monotonic counter (RFC 9562 §6.2 Method 1)

/// Per-process monotonic counter + clock-rewind watermark. Internal so
/// tests can instantiate fresh ones; production uses the `shared` instance.
final class MonotonicCounter: @unchecked Sendable {
    static let shared = MonotonicCounter()

    private let lock = NSLock()
    private var previousMs: UInt64 = 0
    private var sequence: UInt16 = 0

    init() {}

    /// Returns `(millis, seq)` to embed in the next UUID, advancing the
    /// counter so the resulting UUID is strictly greater than the previous
    /// one emitted from this counter.
    func advance(currentMs: UInt64) -> (UInt64, UInt16) {
        lock.lock()
        defer { lock.unlock() }

        var ms = currentMs
        if ms > previousMs {
            // Clock advanced — reset counter.
            sequence = 0
        } else {
            // Same ms, or clock went backwards. Pin to previous ms and
            // bump the sequence so ordering is preserved.
            ms = previousMs
            sequence &+= 1
            if sequence > 0xFFF {
                // Counter overflow: carry into the next millisecond.
                sequence = 0
                ms &+= 1
            }
        }
        previousMs = ms
        return (ms, sequence)
    }
}

// MARK: - Random helper (Swift std)

extension SystemRandomNumberGenerator {
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
