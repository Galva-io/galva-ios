//
//  UUIDv7Tests.swift
//  GalvaTests
//
//  Covers two concerns separately:
//
//    1. Bit layout — fed deterministic inputs through
//       `UUIDv7.makeBytes(...)`, asserting the resulting 16 bytes match
//       RFC 9562 §5.7 (version 7 + variant 10xx + 48-bit ms timestamp
//       + 12-bit sequence + 62-bit rand_b).
//
//    2. Monotonicity — `MonotonicCounter` is tested directly against a
//       synthetic clock feed. No reliance on wall-clock timing.
//
//  We deliberately avoid tying tests to `Date()` so they're deterministic
//  and parallel-safe — every test instantiates its own `MonotonicCounter`.
//

import Foundation
@testable import Galva
import XCTest

final class UUIDv7BitLayoutTests: XCTestCase {

    // MARK: - Version + variant

    func test_versionNibble_isAlways7() {
        // Pick a random rand_b — version stamp must override whatever's there.
        let rand: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let uuid = UUIDv7.makeBytes(millis: 0, sequence: 0, randomBytes: rand)
        XCTAssertEqual(byte(uuid, at: 6) >> 4, 0x7, "Top nibble of byte 6 must be 0x7")
    }

    func test_variantBits_areAlways10xx() {
        let rand: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let uuid = UUIDv7.makeBytes(millis: 0, sequence: 0, randomBytes: rand)
        XCTAssertEqual(byte(uuid, at: 8) >> 6, 0b10,
                       "Top two bits of byte 8 must be 10")
    }

    // MARK: - Timestamp packing

    func test_timestamp_packedBigEndianIntoBytes0Through5() {
        // 0x0123_4567_89AB ms
        let millis: UInt64 = 0x0123_4567_89AB
        let uuid = UUIDv7.makeBytes(millis: millis, sequence: 0, randomBytes: zeros())
        XCTAssertEqual(byte(uuid, at: 0), 0x01)
        XCTAssertEqual(byte(uuid, at: 1), 0x23)
        XCTAssertEqual(byte(uuid, at: 2), 0x45)
        XCTAssertEqual(byte(uuid, at: 3), 0x67)
        XCTAssertEqual(byte(uuid, at: 4), 0x89)
        XCTAssertEqual(byte(uuid, at: 5), 0xAB)
    }

    func test_timestamp_higherThan48BitsIsTruncated() {
        // Only low 48 bits are used.
        let millis: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
        let uuid = UUIDv7.makeBytes(millis: millis, sequence: 0, randomBytes: zeros())
        XCTAssertEqual(byte(uuid, at: 0), 0xFF)
        XCTAssertEqual(byte(uuid, at: 5), 0xFF)
    }

    // MARK: - Sequence packing

    func test_sequence_packedIntoLow4BitsOfByte6AndAllOfByte7() {
        let seq: UInt16 = 0xABC // 12 bits, fully populated
        let uuid = UUIDv7.makeBytes(millis: 0, sequence: seq, randomBytes: zeros())
        XCTAssertEqual(byte(uuid, at: 6) & 0x0F, 0x0A, "High nibble of seq → low 4 bits of byte 6")
        XCTAssertEqual(byte(uuid, at: 7), 0xBC, "Low 8 bits of seq → all of byte 7")
    }

    func test_sequence_higherThan12BitsIsTruncated() {
        let seq: UInt16 = 0xF123 // top nibble overflows 12-bit field
        let uuid = UUIDv7.makeBytes(millis: 0, sequence: seq, randomBytes: zeros())
        XCTAssertEqual(byte(uuid, at: 6) & 0x0F, 0x01)
        XCTAssertEqual(byte(uuid, at: 7), 0x23)
    }

    // MARK: - rand_b preservation

    func test_randomBytes_preservedExceptForVariantBits() {
        // Stuff a recognisable pattern into rand_b. Bytes 9..15 should pass
        // through; byte 8's top 2 bits get replaced with variant `10`.
        let rand: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE]
        let uuid = UUIDv7.makeBytes(millis: 0, sequence: 0, randomBytes: rand)
        XCTAssertEqual(byte(uuid, at: 8), 0x80 | (0xDE & 0x3F)) // top 2 → 10
        XCTAssertEqual(byte(uuid, at: 9), 0xAD)
        XCTAssertEqual(byte(uuid, at: 10), 0xBE)
        XCTAssertEqual(byte(uuid, at: 11), 0xEF)
        XCTAssertEqual(byte(uuid, at: 12), 0xCA)
        XCTAssertEqual(byte(uuid, at: 13), 0xFE)
        XCTAssertEqual(byte(uuid, at: 14), 0xBA)
        XCTAssertEqual(byte(uuid, at: 15), 0xBE)
    }

    // MARK: - Helpers

    private func zeros() -> [UInt8] { [UInt8](repeating: 0, count: 8) }

    private func byte(_ uuid: UUID, at index: Int) -> UInt8 {
        withUnsafeBytes(of: uuid.uuid) { ptr in ptr[index] }
    }
}

// MARK: - Monotonicity (RFC 9562 §6.2)

final class UUIDv7MonotonicityTests: XCTestCase {

    func test_clockAdvances_sequenceResetsToZero() {
        let counter = MonotonicCounter()
        _ = counter.advance(currentMs: 100)
        let (ms2, seq2) = counter.advance(currentMs: 200)
        XCTAssertEqual(ms2, 200)
        XCTAssertEqual(seq2, 0)
    }

    func test_sameMillisecond_sequenceIncrements() {
        let counter = MonotonicCounter()
        let (ms1, seq1) = counter.advance(currentMs: 100)
        let (ms2, seq2) = counter.advance(currentMs: 100)
        let (ms3, seq3) = counter.advance(currentMs: 100)
        XCTAssertEqual([ms1, ms2, ms3], [100, 100, 100])
        XCTAssertEqual([seq1, seq2, seq3], [0, 1, 2])
    }

    func test_clockRewind_pinsToPreviousMillisAndIncrements() {
        let counter = MonotonicCounter()
        _ = counter.advance(currentMs: 1000)
        // Wall clock rewinds 500ms.
        let (ms, seq) = counter.advance(currentMs: 500)
        XCTAssertEqual(ms, 1000, "Must not regress below previousMs")
        XCTAssertEqual(seq, 1)
    }

    func test_sequenceOverflow_carriesIntoNextMillisecond() {
        let counter = MonotonicCounter()
        // Prime: first call goes to ms=100, seq=0.
        _ = counter.advance(currentMs: 100)
        // 0xFFF more same-ms calls take seq from 0 → 0xFFF.
        for _ in 1...0xFFF {
            let (ms, _) = counter.advance(currentMs: 100)
            XCTAssertEqual(ms, 100)
        }
        // The 0x1000th same-ms call overflows: seq resets to 0, ms carries +1.
        let (ms, seq) = counter.advance(currentMs: 100)
        XCTAssertEqual(ms, 101, "Counter overflow must carry into next millisecond")
        XCTAssertEqual(seq, 0)
    }

    func test_strictMonotonicity_acrossManyCalls() {
        // Stress: 5000 calls with a clock that sometimes pauses, sometimes
        // jumps forward. Output must be strictly monotonically increasing.
        let counter = MonotonicCounter()
        var clock: UInt64 = 100
        var produced: [(UInt64, UInt16)] = []
        for i in 0..<5000 {
            switch i % 7 {
            case 0: clock = max(0, clock - 1)         // small rewind
            case 1: clock += 0                         // pause
            case 2: clock += 1                         // tick
            case 3: clock += 5                         // skip ahead
            default: clock += 0                        // pause again
            }
            produced.append(counter.advance(currentMs: clock))
        }
        for i in 1..<produced.count {
            let prev = produced[i - 1]
            let curr = produced[i]
            XCTAssertTrue(
                curr.0 > prev.0 || (curr.0 == prev.0 && curr.1 > prev.1),
                "Non-monotonic at index \(i): \(prev) → \(curr)"
            )
        }
    }
}

// MARK: - Production `UUIDv7.next()`

final class UUIDv7ProductionTests: XCTestCase {

    func test_next_producesVersion7Variant10xxUUIDs() {
        for _ in 0..<50 {
            let uuid = UUIDv7.next()
            let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
            XCTAssertEqual(bytes[6] >> 4, 0x7)
            XCTAssertEqual(bytes[8] >> 6, 0b10)
        }
    }

    func test_next_isMonotonicUnderBurst() {
        // Burst 1000 calls — they share the same shared counter and ordering
        // must hold even when many land in the same millisecond.
        var produced: [UUID] = []
        produced.reserveCapacity(1000)
        for _ in 0..<1000 { produced.append(UUIDv7.next()) }
        for i in 1..<produced.count {
            let prev = produced[i - 1].uuidString
            let curr = produced[i].uuidString
            XCTAssertTrue(curr > prev, "Out-of-order at \(i): \(prev) → \(curr)")
        }
    }

    func test_next_isThreadSafe() async {
        // 4 concurrent producers, 250 UUIDs each = 1000 total. The set must
        // have 1000 distinct elements (no duplicates from a race).
        let total = 1000
        let perTask = 250
        var collected = [UUID]()
        collected.reserveCapacity(total)
        await withTaskGroup(of: [UUID].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var local: [UUID] = []
                    local.reserveCapacity(perTask)
                    for _ in 0..<perTask { local.append(UUIDv7.next()) }
                    return local
                }
            }
            for await batch in group { collected.append(contentsOf: batch) }
        }
        XCTAssertEqual(collected.count, total)
        XCTAssertEqual(Set(collected).count, total, "Race produced duplicates")
    }
}
