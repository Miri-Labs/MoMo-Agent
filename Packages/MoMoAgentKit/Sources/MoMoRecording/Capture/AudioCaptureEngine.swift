import AVFAudio
import Foundation

public enum AudioCaptureError: Error, Equatable {
    case unsupportedInput, unexpectedInputRoute, bufferOverflow, discontinuousInput, alreadyRunning, notRunning
}

public struct CapturedAudioBlock: Sendable {
    public let mono: [Float]
    public let sampleTime: Int64?
    public let uptime: TimeInterval
    public let wallClock: Date
    public let normalizedLevel: Float
}

public struct AudioCaptureInput: Sendable {
    public let sampleRate: Double
    public let blocks: AsyncThrowingStream<CapturedAudioBlock, any Error>
}

/// The tap only copies one bounded PCM block. Encoding, files and SQLite run on its consumer.
@MainActor public final class AudioCaptureEngine {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<CapturedAudioBlock, any Error>.Continuation?
    private var installed = false
    private var tapHealth = CaptureTapHealth()

    /// Nonempty tap arrivals, independent of encoder consumption; remains readable after stop.
    public var healthSnapshot: CaptureDiagnosticTapSnapshot { tapHealth.snapshot() }
    /// A route or configuration change stops AVAudioEngine without finishing the block stream.
    public var isRunning: Bool { installed && engine.isRunning }

    public init() {}

    /// onLevel runs on the audio tap at most once per 100ms bucket and must return immediately.
    public func start(inputAllowed: @escaping @Sendable () -> Bool = { true },
                      levelDeliveryAllowed: @escaping @Sendable () -> Bool = { true },
                      onLevel: (@Sendable (Float, TimeInterval) -> Void)? = nil) throws -> AudioCaptureInput {
        guard !installed else { throw AudioCaptureError.alreadyRunning }
        let health = CaptureTapHealth()
        let levels = CaptureLevelRelay(onLevel: onLevel, deliveryAllowed: levelDeliveryAllowed)
        tapHealth = health
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
              (1...2).contains(format.channelCount), format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved else { throw AudioCaptureError.unsupportedInput }
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let sink = pair.continuation
        // Each tap owns its health counters, so a late old callback cannot affect a new start.
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable buffer, time in
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            health.received(frames: count, at: ProcessInfo.processInfo.systemUptime)
            guard inputAllowed() else {
                sink.finish(throwing: AudioCaptureError.unexpectedInputRoute)
                return
            }
            guard count <= 8_192, let channels = buffer.floatChannelData,
                  (1...2).contains(buffer.format.channelCount) else {
                sink.finish(throwing: AudioCaptureError.unsupportedInput)
                return
            }
            let channelCount = Int(buffer.format.channelCount)
            let (mono, level) = copyCaptureSamples(channels, channelCount: channelCount,
                frames: count, meter: levelDeliveryAllowed())
            let now = ProcessInfo.processInfo.systemUptime
            let uptime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : now
            let block = CapturedAudioBlock(mono: mono, sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
                                          uptime: uptime, wallClock: Date(timeIntervalSinceNow: uptime - now),
                                          normalizedLevel: level)
            // The route gate may close while this callback copies the buffer.
            guard inputAllowed() else {
                sink.finish(throwing: AudioCaptureError.unexpectedInputRoute)
                return
            }
            // Metering must not wait for the consumer to encode, seal or persist a chunk.
            levels.receive(rms: block.normalizedLevel, at: uptime)
            if case .dropped = sink.yield(block) {
                health.dropped()
                sink.finish(throwing: AudioCaptureError.bufferOverflow)
            }
        }
        continuation = sink; installed = true
        do { engine.prepare(); try engine.start() }
        catch { stop(); throw error }
        return AudioCaptureInput(sampleRate: format.sampleRate, blocks: pair.stream)
    }

    public func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
        continuation?.finish()
        continuation = nil
    }
}

/// The built-in mono microphone needs one copy; a hidden meter needs no RMS calculation.
func copyCaptureSamples(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int,
                        frames: Int, meter: Bool) -> (samples: [Float], level: Float) {
    precondition((1...2).contains(channelCount) && (1...8_192).contains(frames))
    var mono = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    if channelCount == 2 {
        for frame in 0..<frames { mono[frame] = (mono[frame] + channels[1][frame]) / 2 }
    }
    guard meter else { return (mono, 0) }
    let sumSquares = mono.reduce(Float.zero) { $0 + $1 * $1 }
    return (mono, min(1, sqrt(sumSquares / Float(frames))))
}

/// Coalesce tap peaks before crossing to the UI; retain no PCM and never wait for its consumer.
final class CaptureLevelRelay: @unchecked Sendable {
    private let lock = NSLock()
    private let onLevel: (@Sendable (Float, TimeInterval) -> Void)?
    private var lastTick: TimeInterval?
    private var peak: Float = 0
    private let deliveryAllowed: @Sendable () -> Bool

    init(onLevel: (@Sendable (Float, TimeInterval) -> Void)?, deliveryAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.onLevel = onLevel; self.deliveryAllowed = deliveryAllowed
    }

    func receive(rms: Float, at uptime: TimeInterval) {
        guard let onLevel, uptime.isFinite, uptime >= 0, rms.isFinite, rms >= 0 else { return }
        guard deliveryAllowed() else {
            lock.withLock { lastTick = nil; peak = 0 }
            return
        }
        let tick = (uptime * 10).rounded(.down)
        guard tick.isFinite else { return }
        lock.lock()
        guard lastTick.map({ tick >= $0 }) ?? true else { lock.unlock(); return }
        peak = max(peak, rms)
        guard tick != lastTick else { lock.unlock(); return }
        lastTick = tick
        let level = peak
        peak = 0
        lock.unlock()
        onLevel(level, uptime)
    }
}

/// Checked on the tap before dispatch; the UI never suspends microphone input or health counters.
public final class CaptureLevelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    public init() {}
    public var isEnabled: Bool { lock.withLock { enabled } }
    public func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
}
