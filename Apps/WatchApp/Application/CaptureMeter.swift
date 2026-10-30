import Foundation
import Observation
import MoMoRecording

@MainActor @Observable
final class CaptureMeter {
    static let columns = 29
    nonisolated let deliveryGate = CaptureLevelGate()
    private(set) var history = Array(repeating: Float.zero, count: columns)
    @ObservationIgnored private var samples = Array(repeating: Float.zero, count: columns)
    @ObservationIgnored private var visible = true
    @ObservationIgnored private var presented = true
    @ObservationIgnored private var lastTick: TimeInterval?
    @ObservationIgnored private var visibleSince: TimeInterval?

    func setVisible(_ value: Bool, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard value != visible else { return }
        visible = value
        deliveryGate.setEnabled(value && presented)
        if value {
            visibleSince = uptime
            history = samples
        }
    }

    func setPresented(_ value: Bool) {
        guard value != presented else { return }
        presented = value
        deliveryGate.setEnabled(visible && value)
        if value { visibleSince = ProcessInfo.processInfo.systemUptime; history = samples }
    }

    /// Advance only the display envelope between encoder callbacks; capture history stays unchanged.
    func displayHistory(at uptime: TimeInterval) -> [Float] {
        guard visible, presented, let lastTick, uptime.isFinite, uptime >= 0 else { return history }
        var offset = max(0, uptime * 10 - lastTick)
        if let visibleSince { offset = min(offset, max(0, (uptime - visibleSince) * 10)) }
        guard offset < Double(Self.columns) else { return Array(repeating: 0, count: Self.columns) }
        func value(at index: Int) -> Float {
            if index < Self.columns { return history[index] }
            // An absent callback contributes decaying display energy, never another audio sample.
            return (history.last ?? 0) * pow(0.72, Float(index - Self.columns + 1))
        }
        return (0..<Self.columns).map { column in
            let position = Double(column) + offset
            let lower = Int(position.rounded(.down)), fraction = Float(position - Double(lower))
            return value(at: lower) * (1 - fraction) + value(at: lower + 1) * fraction
        }
    }

    func record(rms: Float, at uptime: TimeInterval) {
        guard visible, presented else { return }
        let tick = (uptime * 10).rounded(.down)
        guard tick.isFinite, tick >= 0 else { return }
        let rawStrength = Float(Self.strength(for: rms))
        let strength = rawStrength > 0.02 ? rawStrength : 0
        guard let previousTick = lastTick else {
            samples[Self.columns - 1] = strength
            publishHistoryIfChanged()
            lastTick = tick
            return
        }
        guard tick >= previousTick else { return }
        let elapsed = tick - previousTick
        lastTick = tick
        if elapsed == 0 {
            samples[Self.columns - 1] = max(samples[Self.columns - 1], strength)
            publishHistoryIfChanged()
            return
        }

        if elapsed >= Double(Self.columns) {
            // This unlabelled envelope shows observed samples, not wall-clock coverage.
            // A suspended callback must not wipe it and replay a right-to-left entrance on wake.
            samples.removeFirst()
            samples.append(strength)
        } else {
            // Preserve the 10 Hz display envelope using capture timestamps, without a UI timer.
            let steps = Int(elapsed)
            for step in 0..<steps {
                let input: Float = step == steps - 1 ? strength : 0
                let decayed = (samples.last ?? 0) * 0.72
                let displayed = max(input, decayed > 0.02 ? decayed : 0)
                samples.removeFirst()
                samples.append(displayed)
            }
        }
        publishHistoryIfChanged()
    }

    private func publishHistoryIfChanged() {
        // Sub-threshold values draw the same idle dots; do not invalidate SwiftUI for them.
        if visible, history != samples { history = samples }
    }

    func reset() {
        samples = Array(repeating: 0, count: Self.columns)
        history = samples
        lastTick = nil
        visibleSince = nil
    }

    static func strength(for rms: Float) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        // Map the microphone's quiet-to-speech range, rather than compressing it with a fourth root.
        let decibels = 20 * log10(Double(rms))
        return min(1, max(0, (decibels + 55) / 35))
    }
}
