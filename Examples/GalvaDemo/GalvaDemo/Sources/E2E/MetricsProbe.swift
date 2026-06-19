//
//  MetricsProbe.swift
//  GalvaDemo
//
//  Measures the host app's own performance footprint and publishes it for the
//  performance UI tests to read via accessibility labels. Sampled identically
//  whether the SDK is on or off, so the perf suite can report the SDK's cost
//  as a delta (SDK − baseline):
//    • launchMs  — app init → first frame
//    • memoryMB  — phys_footprint (matches Xcode's Memory gauge)
//    • cpuMs     — cumulative CPU time at a fixed settle point
//

import Foundation
import Combine

/// Captured as early as possible in `App.init()` so `launchMs` reflects the
/// init → first-frame window.
enum LaunchClock {
    static let startUptime = ProcessInfo.processInfo.systemUptime
}

final class MetricsProbe: ObservableObject {
    static let shared = MetricsProbe()

    @Published private(set) var launchMs: Double = 0
    @Published private(set) var memoryMB: Double = 0
    @Published private(set) var cpuMs: Double = 0
    /// Set once the post-settle sample has been taken — the test waits on this
    /// before reading the numbers.
    @Published private(set) var ready = false

    private var sampled = false

    private init() {}

    /// Call from the root view's `onAppear`. Records launch time immediately,
    /// then samples memory/CPU after a short settle so transient launch
    /// allocations have drained and the reading is stable.
    func onFirstFrame() {
        guard !sampled else { return }
        sampled = true
        launchMs = (ProcessInfo.processInfo.systemUptime - LaunchClock.startUptime) * 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.memoryMB = Self.physFootprintMB()
            self.cpuMs = Self.cpuMilliseconds()
            self.ready = true
        }
    }

    // MARK: - mach probes

    /// Resident memory (`phys_footprint`) in MB — the same figure Xcode's
    /// Memory gauge and `os_proc_available_memory` accounting use.
    static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024 * 1024)
    }

    /// Cumulative CPU time (user + system) of live threads since launch, in ms.
    static func cpuMilliseconds() -> Double {
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
        let system = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
        return user + system
    }
}
