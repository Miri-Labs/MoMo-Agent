import Foundation

public struct SpeechAnalysisPage: Sendable {
    public let batch: SpeechAnalysisBatch
    public let isFinal: Bool
}

/// One pending page bounds native read-ahead. Archive remains the completion authority.
public final class SpeechAnalysisStream: @unchecked Sendable {
    private let state: SpeechAnalysisChannel
    private let producer: Task<Void, Never>

    init(state: SpeechAnalysisChannel, producer: Task<Void, Never>) {
        self.state = state; self.producer = producer
    }

    deinit { state.cancelIfRunning() }

    public func next() async throws -> SpeechAnalysisPage? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { state.receive($0) }
        } onCancel: { state.cancel() }
    }

    public func cancel() { state.cancel() }
    public func setReadAheadAllowed(_ allowed: Bool) { state.setReadAheadAllowed(allowed) }
    /// Always wait before releasing the original audio lease, including after cancellation.
    public func waitUntilFinished() async { await producer.value }
}

final class SpeechAnalysisChannel: @unchecked Sendable {
    private let condition = NSCondition()
    private let attempt: SpeechAttempt
    private let onCancel: @Sendable () -> Void
    private var buffered: SpeechAnalysisPage?
    private var receiver: CheckedContinuation<SpeechAnalysisPage?, Error>?
    private var terminal: Result<Void, Error>?
    private var cancelled = false
    private var readAheadAllowed: Bool
    private var cancellationObserver: UUID?

    init(attempt: SpeechAttempt, readAheadAllowed: Bool, onCancel: @escaping @Sendable () -> Void) {
        self.attempt = attempt; self.readAheadAllowed = readAheadAllowed; self.onCancel = onCancel
        cancellationObserver = attempt.observeCancellation { [weak self] in self?.cancelState() }
    }

    deinit { if let cancellationObserver { attempt.removeCancellationObserver(cancellationObserver) } }

    func receive(_ continuation: CheckedContinuation<SpeechAnalysisPage?, Error>) {
        condition.lock()
        if cancelled {
            condition.unlock(); continuation.resume(throwing: CancellationError())
        } else if let page = buffered {
            buffered = nil; condition.broadcast(); condition.unlock(); continuation.resume(returning: page)
        } else if let terminal {
            condition.unlock(); continuation.resume(with: terminal.map { nil })
        } else if receiver != nil {
            condition.unlock(); continuation.resume(throwing: SpeechError.incompatibleCheckpoint)
        } else {
            receiver = continuation; condition.broadcast(); condition.unlock()
        }
    }

    /// Blocking is confined to the native analysis queue, never a cooperative executor.
    func waitForDemand(recorder: SpeechDiagnosticRecorder) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        condition.lock()
        while !cancelled && (buffered != nil || (!readAheadAllowed && receiver == nil)) { condition.wait() }
        condition.unlock()
        recorder.value.analysisBackpressureSeconds += SpeechDiagnosticRecorder.seconds(since: start)
        try attempt.checkCancellation()
    }

    func send(_ page: SpeechAnalysisPage) throws {
        condition.lock()
        do { try attempt.checkCancellation() }
        catch { condition.unlock(); throw error }
        guard !cancelled, buffered == nil else { condition.unlock(); throw CancellationError() }
        let waiting = receiver; receiver = nil
        if waiting == nil { buffered = page }
        condition.unlock()
        waiting?.resume(returning: page)
    }

    func finish(_ result: Result<Void, Error>) {
        condition.lock()
        terminal = result
        if case .failure = result { buffered = nil }
        let waiting = receiver; receiver = nil
        condition.broadcast(); condition.unlock()
        waiting?.resume(with: result.map { nil })
    }

    func setReadAheadAllowed(_ allowed: Bool) {
        condition.lock(); readAheadAllowed = allowed; condition.broadcast(); condition.unlock()
    }

    func cancelIfRunning() {
        condition.lock(); let running = terminal == nil; condition.unlock()
        if running { cancel() }
    }

    func cancel() {
        attempt.cancel()
        cancelState()
    }

    private func cancelState() {
        condition.lock()
        guard !cancelled else { condition.unlock(); return }
        cancelled = true; buffered = nil
        let waiting = receiver; receiver = nil
        condition.broadcast(); condition.unlock()
        onCancel()
        waiting?.resume(throwing: CancellationError())
    }
}
