import Foundation

/// All mutable state is protected by the lock; no audio or per-block history is retained.
final class CaptureTapHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedFrames: Int64 = 0
    private var receivedBlocks: Int64 = 0
    private var droppedBlocks: Int64 = 0
    private var lastTapUptime: TimeInterval?

    func received(frames: Int, at uptime: TimeInterval) {
        guard frames > 0, uptime.isFinite, uptime >= 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        receivedFrames = Self.adding(Int64(frames), to: receivedFrames)
        receivedBlocks = Self.adding(1, to: receivedBlocks)
        lastTapUptime = max(lastTapUptime ?? uptime, uptime)
    }

    func dropped() {
        lock.lock()
        defer { lock.unlock() }
        droppedBlocks = Self.adding(1, to: droppedBlocks)
    }

    func snapshot() -> CaptureDiagnosticTapSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CaptureDiagnosticTapSnapshot(receivedFrames: receivedFrames, receivedBlocks: receivedBlocks,
                                            droppedBlocks: droppedBlocks, lastTapUptime: lastTapUptime)
    }

    private static func adding(_ increment: Int64, to value: Int64) -> Int64 {
        let result = value.addingReportingOverflow(increment)
        return result.overflow ? .max : result.partialValue
    }
}
