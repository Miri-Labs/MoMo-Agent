import Foundation

/// Keep every encoder observation; notify active UI each second and hidden UI at chunk cadence.
public final class CaptureProgressDelivery: @unchecked Sendable {
    public let updates: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: CaptureProgress?
    private var latestProgress: CaptureProgress?
    private var hasSealedChunk = false
    private var observedAt: TimeInterval?
    private var notifiedFrames: Int64?
    private var finished = false
    private var presentationActive: Bool

    public init(presentationActive: Bool = true) {
        self.presentationActive = presentationActive
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        updates = pair.stream
        continuation = pair.continuation
    }

    public func setPresentationActive(_ active: Bool) {
        lock.lock()
        guard !finished, active != presentationActive else { lock.unlock(); return }
        presentationActive = active
        let notify = active && latestProgress != nil
        if notify {
            pending = latestProgress
            notifiedFrames = latestProgress?.frames
        }
        lock.unlock()
        if notify { continuation.yield(()) }
    }

    public var lastReceivedAt: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return observedAt
    }

    /// Marks and status requests read this even between UI notifications.
    public var latest: CaptureProgress? {
        lock.lock(); defer { lock.unlock() }
        return latestProgress
    }

    @discardableResult public func receive(_ progress: CaptureProgress) -> Bool {
        lock.lock()
        guard !finished else { lock.unlock(); return false }
        pending = progress
        latestProgress = progress
        hasSealedChunk = hasSealedChunk || progress.sealedChunkID != nil
        observedAt = ProcessInfo.processInfo.systemUptime
        let intervalFrames: Int64 = presentationActive ? 16_000 : 60 * 16_000
        let notify = notifiedFrames == nil || progress.sealedChunkID != nil ||
            (notifiedFrames == 0 && progress.frames > 0) ||
            notifiedFrames.map { $0 / intervalFrames != progress.frames / intervalFrames } == true
        if notify { notifiedFrames = progress.frames }
        lock.unlock()
        if notify { continuation.yield(()) }
        return notify
    }

    public func take() -> (progress: CaptureProgress, hasSealedChunk: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard let pending else { return nil }
        let result = (pending, hasSealedChunk)
        self.pending = nil
        hasSealedChunk = false
        return result
    }

    public func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let hasPending = pending != nil
        lock.unlock()
        if hasPending { continuation.yield(()) }
        continuation.finish()
    }
}
