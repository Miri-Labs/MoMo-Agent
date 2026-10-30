import Dispatch
import Foundation
import Testing
@testable import MoMoRecording

struct CaptureTapHealthTests {
    @Test func hiddenWaveformDispatchesNothingAndWakesWithFreshSamples() {
        let gate = CaptureLevelGate(), health = CaptureTapHealth(), delivered = LevelValues()
        let relay = CaptureLevelRelay(onLevel: { level, _ in delivered.append(level) }, deliveryAllowed: { gate.isEnabled })
        relay.receive(rms: 0.01, at: 0)
        relay.receive(rms: 0.9, at: 0.05) // Unpublished peak must not survive the hidden interval.
        gate.setEnabled(false)
        for tick in 1...36_000 {
            health.received(frames: 1_024, at: Double(tick) / 10)
            relay.receive(rms: 1, at: Double(tick) / 10)
        }
        #expect(delivered.values == [0.01])
        #expect(health.snapshot().receivedBlocks == 36_000)
        gate.setEnabled(true)
        relay.receive(rms: 0.02, at: 3_601)
        #expect(delivered.values == [0.01, 0.02], "Hidden peaks must not replay on wake")
    }

    @Test func newCaptureCountersDoNotReusePriorTapOrEmptyCallbacks() {
        let previous = CaptureTapHealth()
        previous.received(frames: 1_024, at: 10)
        let current = CaptureTapHealth()
        previous.received(frames: 512, at: 11)
        previous.dropped()
        current.received(frames: 0, at: 12)
        #expect(current.snapshot() == CaptureDiagnosticTapSnapshot(receivedFrames: 0, receivedBlocks: 0,
                                                                  droppedBlocks: 0, lastTapUptime: nil))
        current.received(frames: 256, at: 13)
        let saved = previous.snapshot()
        #expect(saved.receivedFrames == 1_536 && saved.receivedBlocks == 2 && saved.droppedBlocks == 1)
        #expect(saved.lastTapUptime == 11)
        #expect(current.snapshot().receivedFrames == 256 && current.snapshot().droppedBlocks == 0)
        #expect(previous.snapshot() == saved)
    }

    @Test func actualBoundedStreamCountsOnlyDroppedYieldAsOverflow() {
        let health = CaptureTapHealth()
        let pair = AsyncThrowingStream<Int, any Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        for index in 0..<33 {
            health.received(frames: 1_024, at: Double(index))
            if case .dropped = pair.continuation.yield(index) {
                health.dropped()
                pair.continuation.finish(throwing: AudioCaptureError.bufferOverflow)
            }
        }
        let snapshot = health.snapshot()
        #expect(snapshot.receivedFrames == 33 * 1_024 && snapshot.receivedBlocks == 33)
        #expect(snapshot.droppedBlocks == 1 && snapshot.lastTapUptime == 32)
        if case .terminated = pair.continuation.yield(34) {} else { Issue.record("Overflow must terminate the stream") }
        #expect(health.snapshot() == snapshot)
    }

    @Test func concurrentCallbacksAndSnapshotsKeepExactTotalsAndLatestArrival() {
        let health = CaptureTapHealth()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            health.received(frames: 64, at: Double(index))
            if index.isMultiple(of: 10) { health.dropped() }
            let snapshot = health.snapshot()
            #expect(snapshot.receivedFrames == snapshot.receivedBlocks * 64)
            #expect(snapshot.droppedBlocks <= snapshot.receivedBlocks)
        }
        #expect(health.snapshot() == CaptureDiagnosticTapSnapshot(receivedFrames: 64_000, receivedBlocks: 1_000,
                                                                droppedBlocks: 100, lastTapUptime: 999))
    }
}

private final class LevelValues: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Float] = []
    var values: [Float] { lock.withLock { recorded } }
    func append(_ level: Float) { lock.withLock { recorded.append(level) } }
}
