import AVFoundation
import Foundation
import MoMoArchive

/// The queue owns the player and session. The lock only publishes cancellation; it never covers native calls.
final class PlaybackAudioSession: @unchecked Sendable {
    struct Progress: Sendable {
        let currentTime: TimeInterval
        let isPlaying: Bool
        let finished: Bool
        let awaitingCompletion: Bool
    }

    private let queue = DispatchQueue(label: "MoMoAgent.playback-session", qos: .userInitiated)
    private let requestLock = NSLock()
    private var requestedAttempt: UInt64?
    private var activeAttempt: UInt64?
    private var player: AVAudioPlayer?
    private var temporaryClip: URL?
    private var logicalDuration: Double = 0
    private var stoppedObservedAt: ContinuousClock.Instant?
    private let completion = PlaybackCompletion()
    private let activateSession: @Sendable () throws -> Void
    private let deactivateSession: @Sendable () throws -> Void
    private let preparePlayer: @Sendable (AVAudioPlayer) throws -> Bool
    private let startPlayer: @Sendable (AVAudioPlayer) -> Bool

    init(activate: @escaping @Sendable () throws -> Void = {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }, deactivate: @escaping @Sendable () throws -> Void = {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }, prepare: @escaping @Sendable (AVAudioPlayer) throws -> Bool = { $0.prepareToPlay() },
         start: @escaping @Sendable (AVAudioPlayer) -> Bool = { $0.play() }) {
        activateSession = activate
        deactivateSession = deactivate
        preparePlayer = prepare
        startPlayer = start
    }

    // MainActor entry keeps enqueue order equal to playback ownership changes, even before suspension.
    @MainActor func activate(for attempt: UInt64) async throws {
        requestLock.withLock { requestedAttempt = attempt }
        try await withTaskCancellationHandler {
            try await perform { [self] in
                try requireRequested(attempt)
                // Even a failed activation can leave partial session configuration to clean up.
                activeAttempt = attempt
                try activateSession()
                try requireRequested(attempt)
            }
        } onCancel: { self.cancelRequest(attempt) }
    }

    @MainActor func begin(_ part: AudioPlaybackPart, offset: Double = 0, for attempt: UInt64) async throws {
        try await prepare(part, offset: offset, for: attempt)
        try await startPrepared(for: attempt)
    }

    @MainActor func prepare(_ part: AudioPlaybackPart, offset: Double = 0, for attempt: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await perform { [self] in try beginOnQueue(part, offset: offset, for: attempt) }
        } onCancel: { self.cancelRequest(attempt) }
    }

    @MainActor func startPrepared(for attempt: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await perform { [self] in
                try requireRequested(attempt)
                guard activeAttempt == attempt, let player else { throw CancellationError() }
                guard startPlayer(player) else { throw PlaybackError.unavailable }
                try requireRequested(attempt)
            }
        } onCancel: { self.cancelRequest(attempt) }
    }

    @MainActor func validate(_ part: AudioPlaybackPart) async throws {
        try await perform { _ = try PlaybackPCMReader(part: part) }
    }

    @MainActor func progress(for attempt: UInt64) async throws -> Progress {
        try await perform { [self] in
            try requireRequested(attempt)
            guard activeAttempt == attempt else { throw CancellationError() }
            guard let player else { throw PlaybackError.unavailable }
            return progressOnQueue(player)
        }
    }

    @MainActor func pause(for attempt: UInt64) async throws -> Progress {
        try await perform { [self] in
            try requireRequested(attempt)
            guard activeAttempt == attempt, let player else { throw CancellationError() }
            player.pause()
            return progressOnQueue(player)
        }
    }

    @MainActor func deactivate(for attempt: UInt64) async throws {
        // A pending prepare must see stop immediately, without making the main thread wait for it.
        cancelRequest(attempt)
        try await perform { [self] in
            guard activeAttempt == attempt else { return }
            stopPlayer()
            try deactivateSession()
            activeAttempt = nil
        }
    }

    private func beginOnQueue(_ part: AudioPlaybackPart, offset: Double, for attempt: UInt64) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try requireRequested(attempt)
        guard activeAttempt == attempt else { throw CancellationError() }
        stopPlayer()
        do {
            let source = try PlaybackPCMReader(part: part)
            logicalDuration = source.duration
            guard offset.isFinite, offset >= 0, offset < logicalDuration else { throw PlaybackError.unavailable }
            let url: URL
            if source.coversEntireFile {
                url = part.lease.audioURL
            } else {
                // A citation must end at its frame boundary in the native player, not at the next UI poll.
                let clip = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPlayback-\(UUID()).caf")
                temporaryClip = clip
                try source.writeClip(to: clip) { [self] in try requireRequested(attempt) }
                url = clip
            }
            let audio = try AVAudioPlayer(contentsOf: url)
            player = audio
            completion.reset(for: audio)
            audio.delegate = completion
            audio.currentTime = offset
            guard try preparePlayer(audio) else { throw PlaybackError.unavailable }
            try requireRequested(attempt)
        } catch {
            stopPlayer()
            throw error
        }
    }

    private func stopPlayer() {
        dispatchPrecondition(condition: .onQueue(queue))
        player?.stop()
        player = nil
        if let temporaryClip { try? FileManager.default.removeItem(at: temporaryClip) }
        temporaryClip = nil
        completion.reset()
        stoppedObservedAt = nil
    }

    private func progressOnQueue(_ player: AVAudioPlayer) -> Progress {
        let finished = completion.finished
        let isPlaying = player.isPlaying
        // AVAudioPlayer can clear isPlaying before delivering its completion delegate.
        // Keep that handoff bounded; an OS stop without completion remains resumable.
        if isPlaying || finished { stoppedObservedAt = nil }
        else if stoppedObservedAt == nil { stoppedObservedAt = .now }
        let awaitingCompletion = stoppedObservedAt.map { $0.duration(to: .now) < .milliseconds(250) } ?? false
        return Progress(currentTime: finished ? logicalDuration : min(logicalDuration, max(0, player.currentTime)),
                        isPlaying: isPlaying, finished: finished, awaitingCompletion: awaitingCompletion)
    }

    private func requireRequested(_ attempt: UInt64) throws {
        guard requestLock.withLock({ requestedAttempt == attempt }) else { throw CancellationError() }
    }

    private func cancelRequest(_ attempt: UInt64) {
        requestLock.withLock { if requestedAttempt == attempt { requestedAttempt = nil } }
    }

    @MainActor private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// AVAudioPlayerDelegate's SDK annotation must not infer MainActor ownership for this queue-owned,
// lock-protected observer. No native audio call or mutable state is transferred to the main actor.
private nonisolated final class PlaybackCompletion: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var identity: ObjectIdentifier?
    var finished: Bool { lock.withLock { value } }
    func reset(for player: AVAudioPlayer? = nil) {
        lock.withLock { value = false; identity = player.map(ObjectIdentifier.init) }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        lock.withLock { if identity == ObjectIdentifier(player) { value = flag } }
    }
}
