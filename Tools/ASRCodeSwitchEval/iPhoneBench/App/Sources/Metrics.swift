import Darwin
import Foundation
import os

struct MemorySnapshot {
    /// What jetsam counts against the app's limit.
    let footprint: UInt64
    /// Kernel-tracked lifetime peak of phys_footprint for this process.
    let peakFootprint: UInt64
    /// Bytes left before the app's jetsam limit (os_proc_available_memory).
    let available: UInt64

    static func now() -> MemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return MemorySnapshot(footprint: info.phys_footprint, peakFootprint: UInt64(max(0, info.ledger_phys_footprint_peak)),
                              available: UInt64(os_proc_available_memory()))
    }
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func thermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
}

/// Samples memory every 100 ms so short spikes between decode calls are not missed.
final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var minAvailable = UInt64.max
    private var maxThermal = ProcessInfo.ThermalState.nominal
    private var timer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "bench.memory", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel(); timer = nil }

    @discardableResult func sample() -> MemorySnapshot {
        let snapshot = MemorySnapshot.now()
        let thermal = ProcessInfo.processInfo.thermalState
        lock.lock()
        minAvailable = min(minAvailable, snapshot.available)
        if thermal.rawValue > maxThermal.rawValue { maxThermal = thermal }
        lock.unlock()
        return snapshot
    }

    var minimumAvailable: UInt64 { lock.lock(); defer { lock.unlock() }; return minAvailable }
    var maximumThermal: ProcessInfo.ThermalState { lock.lock(); defer { lock.unlock() }; return maxThermal }
}
