//
//  PerformanceUITests.swift
//  GalvaDemoUITests
//
//  Measures the SDK's footprint in a real running app as a delta against a
//  baseline with no Galva at all (GALVA_PERF_BASELINE). Launches each mode
//  N times, takes the median, and:
//    • GATES on extra resident memory (fails the build if over budget),
//    • reports launch-time + CPU deltas (informational, noisy on shared CI).
//
//  The before/after table is printed between sentinel markers (extracted by
//  scripts/perf.sh into perf-report.md) and attached to the xcresult.
//

import XCTest

final class PerformanceUITests: XCTestCase {

    /// Gating budget — extra resident memory the SDK may add at idle.
    private let memoryBudgetMB = 8.0
    /// Report-only reference for launch overhead.
    private let launchReferenceMs = 150.0

    private let runs = 5

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_sdkOverhead_withinBudget() {
        let baseline = sample(sdkEnabled: false)
        let sdk = sample(sdkEnabled: true)

        guard !baseline.isEmpty, !sdk.isEmpty else {
            XCTFail("perf probe never became ready (baseline=\(baseline.count), sdk=\(sdk.count))")
            return
        }

        let baseMem = median(baseline.map(\.memoryMB)), sdkMem = median(sdk.map(\.memoryMB))
        let baseLaunch = median(baseline.map(\.launchMs)), sdkLaunch = median(sdk.map(\.launchMs))
        let baseCpu = median(baseline.map(\.cpuMs)), sdkCpu = median(sdk.map(\.cpuMs))

        let memDelta = sdkMem - baseMem
        let launchDelta = sdkLaunch - baseLaunch
        let cpuDelta = sdkCpu - baseCpu

        emitReport(rows: [
            Row("Resident memory (MB)", baseMem, sdkMem, memDelta,
                budget: "< \(fmt(memoryBudgetMB))", gating: true, pass: memDelta < memoryBudgetMB),
            Row("Launch (ms)", baseLaunch, sdkLaunch, launchDelta,
                budget: "ref \(fmt(launchReferenceMs))", gating: false, pass: true),
            Row("CPU (ms)", baseCpu, sdkCpu, cpuDelta,
                budget: "report-only", gating: false, pass: true),
        ])

        // GATE: extra resident memory must stay under budget.
        XCTAssertLessThan(
            memDelta, memoryBudgetMB,
            "SDK adds \(fmt(memDelta)) MB resident memory at idle (baseline \(fmt(baseMem)) → SDK \(fmt(sdkMem))) — over the \(fmt(memoryBudgetMB)) MB budget"
        )
        // Launch + CPU are informational (no assertion); they live in the report.
    }

    // MARK: - Sampling

    private struct Metrics { let memoryMB, launchMs, cpuMs: Double }

    private func sample(sdkEnabled: Bool) -> [Metrics] {
        var out: [Metrics] = []
        for _ in 0..<runs {
            let app = launchAppPerf(sdkEnabled: sdkEnabled)
            if let m = readMetrics(app) {
                out.append(Metrics(memoryMB: m.memoryMB, launchMs: m.launchMs, cpuMs: m.cpuMs))
            }
            app.terminate()
        }
        return out
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.filter { !$0.isNaN }.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[sorted.count / 2]
    }

    private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }

    // MARK: - Report

    private struct Row {
        let name: String, baseline: Double, sdk: Double, delta: Double
        let budget: String, gating: Bool, pass: Bool
        init(_ name: String, _ baseline: Double, _ sdk: Double, _ delta: Double,
             budget: String, gating: Bool, pass: Bool) {
            self.name = name; self.baseline = baseline; self.sdk = sdk; self.delta = delta
            self.budget = budget; self.gating = gating; self.pass = pass
        }
    }

    private func emitReport(rows: [Row]) {
        var md = "# Galva SDK performance report\n\n"
        md += "Median of \(runs) runs each — host app **with** the SDK vs **without** (baseline).\n\n"
        md += "| Metric | Baseline | With SDK | Delta | Budget | Status |\n"
        md += "|---|---|---|---|---|---|\n"
        for row in rows {
            let status = row.gating ? (row.pass ? "✅ pass" : "❌ FAIL") : "—"
            let sign = row.delta >= 0 ? "+" : ""
            md += "| \(row.name) | \(fmt(row.baseline)) | \(fmt(row.sdk)) | \(sign)\(fmt(row.delta)) | \(row.budget) | \(status) |\n"
        }

        // Printed for scripts/perf.sh to extract; attached for the xcresult.
        print("===GALVA-PERF-REPORT-BEGIN===")
        print(md)
        print("===GALVA-PERF-REPORT-END===")

        let attachment = XCTAttachment(string: md)
        attachment.name = "perf-report.md"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
