//
//  BackoffTests.swift
//  GalvaTests
//
//  Pure-math tests for the exponential-jitter backoff used by the queue's
//  retry loop. We run each attempt N times and assert the empirical range
//  matches the documented bounds.
//

import Foundation
@testable import Galva
import XCTest

final class BackoffTests: XCTestCase {

    /// Number of samples per attempt — enough to reliably observe the full
    /// range without test runtime ballooning.
    private let samples = 500

    func test_attemptZero_isAlwaysImmediate() {
        for _ in 0..<samples {
            XCTAssertEqual(Backoff.delay(forAttempt: 0), 0)
        }
    }

    func test_delayIsAlwaysNonNegative() {
        for attempt in 0...8 {
            for _ in 0..<samples {
                let d = Backoff.delay(forAttempt: attempt)
                XCTAssertGreaterThanOrEqual(d, 0, "Negative delay at attempt \(attempt)")
            }
        }
    }

    func test_perAttemptCeiling_isMinOf60AndPow2() {
        // attempt N: delay in 0 ... min(60, 2^N).
        for attempt in 1...10 {
            let ceiling = min(60.0, pow(2.0, Double(attempt)))
            for _ in 0..<samples {
                let d = Backoff.delay(forAttempt: attempt)
                XCTAssertLessThanOrEqual(d, ceiling,
                    "attempt \(attempt) exceeded ceiling \(ceiling) with value \(d)")
            }
        }
    }

    func test_ceiling_capsAt60Seconds() {
        // For attempt 6+ the 2^N value exceeds 60, so the cap is the
        // binding constraint.
        for attempt in 6...20 {
            for _ in 0..<samples {
                let d = Backoff.delay(forAttempt: attempt)
                XCTAssertLessThanOrEqual(d, 60.0)
            }
        }
    }

    func test_meanGrowsWithAttempt_uptoCap() {
        // We don't assert exact means (it's random), but the mean of many
        // samples should be roughly base/2. Compare attempt 1 to attempt 4
        // to confirm growth.
        let mean1 = mean(of: 1, samples: 2000)
        let mean4 = mean(of: 4, samples: 2000)
        XCTAssertGreaterThan(mean4, mean1,
            "Mean(attempt=4)=\(mean4) should exceed mean(attempt=1)=\(mean1)")
    }

    func test_attempt1_samplesCoverFullRange() {
        // For attempt 1, ceiling = 2. We expect samples to span well below
        // and well above the midpoint.
        var sawLow = false
        var sawHigh = false
        for _ in 0..<200 {
            let d = Backoff.delay(forAttempt: 1)
            if d < 0.5 { sawLow = true }
            if d > 1.5 { sawHigh = true }
            if sawLow && sawHigh { break }
        }
        XCTAssertTrue(sawLow, "Jitter never produced a value < 0.5 in 200 tries")
        XCTAssertTrue(sawHigh, "Jitter never produced a value > 1.5 in 200 tries")
    }

    // MARK: - Helpers

    private func mean(of attempt: Int, samples: Int) -> Double {
        var total = 0.0
        for _ in 0..<samples {
            total += Backoff.delay(forAttempt: attempt)
        }
        return total / Double(samples)
    }
}
