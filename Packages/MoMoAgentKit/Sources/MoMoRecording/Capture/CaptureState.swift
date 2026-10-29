import Foundation

public enum CaptureIntent: String, Codable, Sendable { case recording, paused, stopped }
public enum CaptureActivity: String, Codable, Sendable { case idle, starting, recording, interrupted, stopped, failed }

public struct CaptureState: Equatable, Sendable {
    public private(set) var intent: CaptureIntent = .stopped
    public private(set) var activity: CaptureActivity = .idle
    public private(set) var generation: UInt64 = 0
    public private(set) var capturedFrames: Int64 = 0
    public private(set) var lastSampleUptime: TimeInterval?

    public init() {}

    /// The generation identifies a capture attempt, so late callbacks cannot restart old audio.
    @discardableResult public mutating func start() -> UInt64 {
        generation += 1
        intent = .recording
        activity = .starting
        capturedFrames = 0
        lastSampleUptime = nil
        return generation
    }

    @discardableResult public mutating func receivedSamples(frames: Int64, uptime: TimeInterval, generation: UInt64) -> Bool {
        guard generation == self.generation, intent == .recording,
              activity == .starting || activity == .recording,
              frames > 0, uptime.isFinite, uptime >= (lastSampleUptime ?? 0),
              capturedFrames <= Int64.max - frames else { return false }
        capturedFrames += frames
        lastSampleUptime = uptime
        activity = .recording
        return true
    }

    public mutating func pause() { intent = .paused; activity = .stopped; generation += 1 }
    public mutating func stop() { intent = .stopped; activity = .stopped; generation += 1 }
    public mutating func interrupt() { activity = .interrupted; generation += 1 }

    @discardableResult public mutating func resumeAfterInterruption(systemAllows: Bool) -> UInt64? {
        guard intent == .recording, activity == .interrupted, systemAllows else { return nil }
        generation += 1
        activity = .starting
        return generation
    }

    public mutating func fail() { activity = .failed; generation += 1 }

    public mutating func restore(intent: CaptureIntent) {
        self.intent = intent
        activity = intent == .recording ? .interrupted : .stopped
        generation += 1
        capturedFrames = 0
        lastSampleUptime = nil
    }
}

/// Used on the serial capture processing queue; the platform callback owns synchronization.
public struct PCMBuffer: Sendable {
    public let maximumFrames: Int
    public private(set) var samples: [Int16] = []

    public init(maximumFrames: Int) throws {
        guard maximumFrames > 0 else { throw PCMBufferError.invalidCapacity }
        self.maximumFrames = maximumFrames
    }

    public mutating func append(_ incoming: [Int16]) throws {
        guard incoming.count <= maximumFrames - samples.count else {
            throw PCMBufferError.overflow(rejectedFrames: incoming.count)
        }
        samples.append(contentsOf: incoming)
    }

    public mutating func drain() -> [Int16] {
        let result = samples
        samples.removeAll(keepingCapacity: true)
        return result
    }
}

public enum PCMBufferError: Error, Equatable { case invalidCapacity, overflow(rejectedFrames: Int) }
