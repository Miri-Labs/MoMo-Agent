import Foundation
import os
import MoMoArchive
import MoMoContracts
import MoMoSpeech

public struct TranscriptionExecutionHandle: Sendable, Equatable {
    public let id: UUID
    public let origin: TranscriptionBatchOrigin
    public let batchExecution: TranscriptionBatchExecution?
}

public struct TranscriptionExecutionCompletion: Sendable {
    public let execution: TranscriptionExecutionHandle
    public let reason: TranscriptionBatchEndReason
    public let failureCode: String?
}

public enum TranscriptionExecutionError: Error, Sendable {
    case busy, userPaused, invalidOrigin
}

public enum TranscriptionPhase: String, Codable, Sendable {
    case idle, preparing, transcribing, queued, waitingForAudio, waitingForContext, waitingForRetry, audioUnavailable
    case paused, systemSuspended, failed
}

public enum TranscriptionResourceConstraint: String, Codable, Sendable {
    case lowPower, thermalPressure
}

public struct TranscriptionSnapshot: Sendable {
    public let phase: TranscriptionPhase
    public let userPaused: Bool
    public let activeSessionID: UUID?
    public let completedWindows: Int
    public let failureCode: String?
    public let execution: TranscriptionExecutionHandle?
    public let batch: TranscriptionBatch?
    /// True until the current Speech call returns, including native preparation and decoding.
    public let nativeInFlight: Bool
    public var failedSessionID: UUID? = nil
    public var failureScope: TranscriptionFailureScope? = nil
    public var historicalResourceConstraint: TranscriptionResourceConstraint? = nil
    public var completedPreparations: Int = 0
}

public struct TranscriptionRunReport: Sendable {
    public let snapshot: TranscriptionSnapshot
    public let preparedBatches: Int
    public let transcribedWindows: Int
}

/// Coalesce expensive library work while retaining immediate state and a final refresh.
struct TranscriptionRefreshGate {
    private var lastRefresh: ContinuousClock.Instant?
    private var wasSettled = false

    mutating func shouldRefresh(completedNewWindow: Bool, settled: Bool,
                                now: ContinuousClock.Instant = ContinuousClock.now) -> Bool {
        if settled {
            let refresh = !wasSettled || completedNewWindow
            wasSettled = true
            lastRefresh = nil
            return refresh
        }
        wasSettled = false
        guard completedNewWindow else { return false }
        if let lastRefresh, lastRefresh.duration(to: now) < .seconds(2) { return false }
        lastRefresh = now
        return true
    }
}

/// Stateless WAL-driven continuous transcription coordinator:
/// - Stage 1 (`prepare`): bounded 120 s stateless Silero VAD + causal P98 gain warmup + Cut & Merge,
///   marking silent intervals (`no_speech`) complete in ~0.15 s and publishing speech windows to SQLite
///   without holding suspended VAD streams or long-lived epoch locks.
/// - Stage 2 (`transcribe`): CoreML/ONNX ASR + speaker diarization over discrete SQLite speech windows.
/// - Single unified scheduler (`claimNextWALStep`): live wearable WAL audio (`Tier 0`) and user-focused
///   views (`Tier 1`) automatically interleave ahead of offline/batch backfills via `WALBackfillPacer`.
public actor TranscriptionCoordinator {
    private static let walVADStepSeconds: Double = 120

    private let archive: ArchiveStore
    private let speech: SpeechEngine
    private let preferencesURL: URL
    private let onStateChanged: @Sendable (TranscriptionSnapshot) -> Void
    private let onVoiceprintUpdated: @Sendable () -> Void
    private let remainingFiniteBackgroundSeconds: (@Sendable () async -> TimeInterval?)?
    private var userPaused: Bool
    private var systemSuspended: Bool
    private var foregroundContinuationAllowed = false
    private var userIntentRevision: UInt64 = 0
    private var sceneRevision: UInt64 = 0
    private var lastUserPauseRevision: UInt64 = 0
    private var lastSceneSuspensionRevision: UInt64 = 0
    private var phase: TranscriptionPhase = .idle
    private var activeSessionID: UUID?
    private var attempt: SpeechAttempt?
    private var activeWork: ActiveWork?
    private var pendingClaim: PendingClaim?
    private var worker: Task<TranscriptionRunReport, Never>?
    private var requested = false
    private var restartAfterCancellation = false
    private var completedWindows = 0
    private var completedPreparations = 0
    private var lastTranscribedWindowCount = 0
    private var batchDecodeFailed = false
    private var failureCode: String?
    private var managed: ManagedTranscriptionExecution?
    private var finiteBackgroundExecutionID: UUID?
    private var startingManaged = false
    private var activeExecutionID: UUID?
    private var batchSnapshot: TranscriptionBatch?
    private var nativeInFlight = false
    private var failedSessionID: UUID?
    private var failureScope: TranscriptionFailureScope?
    private var lastAttemptedSessionID: UUID?
    private var retryScope: (sessionID: UUID, generation: Int64)?
    private var retrySources: [TimelineAudioSource]?
    private var startingRetry = false
    private var automaticWorkAfterRetry = false
    private var readingSequences: [ReadingSequenceEntry] = []
    private var stopBarrier: (executionID: UUID, task: Task<Void, Error>)?
    private var retryWakeTask: Task<Void, Never>?
    private var historicalWorkAllowed = true
    private var historicalResourceConstraint: TranscriptionResourceConstraint?
    private var focusedDay: TimelineDay?
    private var focusedSessionID: UUID?
    private var preservedHistoryFingerprint: String?
    private var hotArrivalCreditBoostPending = false
    private let performanceLogger = Logger(subsystem: "com.momoagent.ios", category: "TranscriptionPerformance")
    #if DEBUG
    private var onClaimReturned: (@Sendable (TranscriptionClaimKind, UUID) async -> Void)?
    private var onStopBoundary: (@Sendable (TranscriptionStopBoundary) async -> Void)?
    private var onAdmissionReturned: (@Sendable () async -> Void)?

    func observeClaims(_ observer: @escaping @Sendable (TranscriptionClaimKind, UUID) async -> Void) {
        onClaimReturned = observer
    }

    func observeStops(_ observer: @escaping @Sendable (TranscriptionStopBoundary) async -> Void) {
        onStopBoundary = observer
    }

    func observeAdmissions(_ observer: @escaping @Sendable () async -> Void) {
        onAdmissionReturned = observer
    }
    #endif

    public init(archive: ArchiveStore, speech: SpeechEngine, startSuspended: Bool = true,
                onStateChanged: @escaping @Sendable (TranscriptionSnapshot) -> Void = { _ in },
                onVoiceprintUpdated: @escaping @Sendable () -> Void = {},
                remainingFiniteBackgroundSeconds: (@Sendable () async -> TimeInterval?)? = nil) throws {
        self.archive = archive
        self.speech = speech
        systemSuspended = startSuspended
        self.remainingFiniteBackgroundSeconds = remainingFiniteBackgroundSeconds
        self.onVoiceprintUpdated = onVoiceprintUpdated
        self.onStateChanged = onStateChanged
        preferencesURL = archive.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/transcription-preferences.json")
        if FileManager.default.fileExists(atPath: preferencesURL.path) {
            userPaused = try WireJSON.decode(Preferences.self, from: Data(contentsOf: preferencesURL)).userPaused
        } else { userPaused = false }
        phase = userPaused ? .paused : (startSuspended ? .systemSuspended : .idle)
    }

    private var computeLease: TranscriptionComputeLease {
        TranscriptionComputeLease(
            userPaused: userPaused,
            systemSuspended: systemSuspended,
            foregroundContinuationAllowed: foregroundContinuationAllowed,
            startingManagedWithoutHandle: startingManaged,
            managedHandle: managed?.handle,
            managedStopping: managed?.stopping != nil,
            finiteBackgroundExecutionID: finiteBackgroundExecutionID,
            historicalWorkAllowed: historicalWorkAllowed,
            historicalResourceConstraint: historicalResourceConstraint,
            focusedDay: focusedDay,
            focusedSessionID: focusedSessionID
        )
    }

    private var canRun: Bool {
        computeLease.canRun
    }

    public func snapshot() -> TranscriptionSnapshot {
        TranscriptionSnapshot(phase: phase, userPaused: userPaused, activeSessionID: activeSessionID,
                              completedWindows: completedWindows, failureCode: failureCode,
                              execution: managed?.handle, batch: batchSnapshot,
                              nativeInFlight: nativeInFlight,
                              failedSessionID: failedSessionID, failureScope: failureScope,
                              historicalResourceConstraint: historicalResourceConstraint,
                              completedPreparations: completedPreparations)
    }

    deinit { retryWakeTask?.cancel() }

    public func setFocusedDay(_ day: TimelineDay?) {
        guard focusedDay != day else { return }
        focusedDay = day
        if day != nil {
            if managed?.handle.batchExecution != nil, managed?.stopping == nil,
               managed?.handle.origin != .continuedProcessing {
                managed?.interleavePriorityWork = true
            }
            requestWork()
        }
    }

    public func setFocusedSessionID(_ sessionID: UUID?) {
        guard focusedSessionID != sessionID else { return }
        focusedSessionID = sessionID
        if sessionID != nil {
            if managed?.handle.batchExecution != nil, managed?.stopping == nil,
               managed?.handle.origin != .continuedProcessing {
                managed?.interleavePriorityWork = true
            }
            requestWork()
        }
    }

    public func setHistoricalWorkAllowed(_ allowed: Bool, constraint: TranscriptionResourceConstraint? = nil) {
        let reason = allowed ? nil : constraint
        guard historicalWorkAllowed != allowed || historicalResourceConstraint != reason else { return }
        historicalResourceConstraint = reason
        historicalWorkAllowed = allowed
        if allowed { requestWork() }
        publish()
    }

    public func requestWork() {
        retryWakeTask?.cancel(); retryWakeTask = nil
        if startingRetry || retryScope != nil { automaticWorkAfterRetry = true; return }
        requested = true
        guard canRun, worker == nil else { return }
        failureCode = nil
        failedSessionID = nil
        failureScope = nil
        lastAttemptedSessionID = nil
        worker = Task { await self.drain() }
    }

    public func reviewNoSpeech(in interval: DateInterval) async throws -> TimeInterval {
        guard managed == nil, !startingManaged, !startingRetry, retryScope == nil else {
            throw TranscriptionExecutionError.busy
        }
        startingRetry = true
        defer { startingRetry = false; requestWork() }
        let target = captureInvalidationTarget()
        stopCurrentAttempt()
        try await invalidateAttempt(target)
        if let worker { _ = await worker.value }
        try Task.checkCancellation()
        return try await archive.reopenNoSpeech(in: interval, configurationFingerprint: speech.configurationFingerprint)
    }

    /// Explicit recovery remains scoped to this generation; it cannot claim another recording.
    public func retryTranscription(sessionID: UUID, expectedGeneration: Int64, sources: [TimelineAudioSource]? = nil) async throws -> TranscriptionRunReport {
        guard canRun, worker == nil, managed == nil, !startingManaged, !startingRetry, retryScope == nil else {
            throw TranscriptionExecutionError.busy
        }
        let revision = sceneRevision
        startingRetry = true
        do {
            try await archive.prepareTranscriptionRetry(sessionID: sessionID, expectedGeneration: expectedGeneration, sources: sources)
            try Task.checkCancellation()
            guard canRun, sceneRevision == revision else { throw TranscriptionExecutionError.busy }
            retryScope = (sessionID, expectedGeneration)
            retrySources = sources
            failureCode = nil
            failedSessionID = nil
            if let failed = failureScope, failed.sessionID == sessionID, failed.generation == expectedGeneration,
               sources == nil || sources?.contains(where: {
                   $0.epochID == failed.epochID && $0.frames.contains(failed.frames)
               }) == true { failureScope = nil }
            lastAttemptedSessionID = nil
            requested = false
            startingRetry = false
            let task = Task { await self.drain() }
            worker = task
            return await task.value
        } catch {
            startingRetry = false
            if automaticWorkAfterRetry { automaticWorkAfterRetry = false; requestWork() }
            throw error
        }
    }

    /// Used by integration runners; no polling and no main-thread native inference.
    public func runUntilIdle() async -> TranscriptionRunReport {
        requestWork()
        var result = TranscriptionRunReport(snapshot: snapshot(), preparedBatches: 0, transcribedWindows: 0)
        while let task = worker {
            result = await task.value
            if result.snapshot.phase == .failed { break }
        }
        return result
    }

    public func pauseByUser() async throws {
        try WireJSON.encode(Preferences(userPaused: true)).write(
            to: preferencesURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        userIntentRevision &+= 1
        lastUserPauseRevision = userIntentRevision
        let revision = userIntentRevision
        userPaused = true
        requested = false
        let target = captureInvalidationTarget()
        stopCurrentAttempt()
        if let execution = managed?.handle { try await stop(execution: execution, reason: .userPaused) }
        try await invalidateAttempt(target)
        guard revision == userIntentRevision, userPaused else { return }
        phase = .paused
        publish()
    }

    public func resumeByUser() throws {
        try WireJSON.encode(Preferences(userPaused: false)).write(
            to: preferencesURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        userIntentRevision &+= 1
        userPaused = false
        restartAfterCancellation = worker != nil
        phase = systemSuspended ? .systemSuspended : .idle
        publish()
        requestWork()
    }

    public func suspendForSystem(continuingForeground: Bool = false) async {
        sceneRevision &+= 1
        lastSceneSuspensionRevision = sceneRevision
        let revision = sceneRevision
        systemSuspended = true
        foregroundContinuationAllowed = continuingForeground
        // Scene background closes foreground eligibility; an admitted system task keeps its own grant.
        if continuingForeground { requestWork(); publish(); return }
        if let managed, managed.handle.origin != .foreground { publish(); return }
        let target = captureInvalidationTarget()
        stopCurrentAttempt()
        if let execution = managed?.handle {
            do { try await stop(execution: execution, reason: .interrupted) }
            catch { failureCode = "archive_cancel_barrier_failed" }
        }
        do { try await invalidateAttempt(target) }
        catch { failureCode = "archive_cancel_barrier_failed" }
        // A new background grant can arrive without any scene transition.
        guard revision == sceneRevision, systemSuspended, managed == nil else { return }
        phase = userPaused ? .paused : .systemSuspended
        publish()
    }

    public func resumeAfterSystemSuspension() {
        foregroundContinuationAllowed = false
        guard systemSuspended else { return }
        sceneRevision &+= 1
        systemSuspended = false
        restartAfterCancellation = worker != nil
        if managed == nil { phase = userPaused ? .paused : .idle }
        publish()
        requestWork()
    }

    public func clearForegroundContinuation() {
        foregroundContinuationAllowed = false
    }

    /// Releases a finite scene continuation only after all admitted work has drained.
    public func finishForegroundContinuationIfIdle() -> Bool {
        guard systemSuspended, foregroundContinuationAllowed, worker == nil,
              managed == nil, !startingManaged, !startingRetry else { return false }
        foregroundContinuationAllowed = false
        phase = userPaused ? .paused : .systemSuspended
        publish()
        return true
    }

    public func freezeBatch() async throws -> TranscriptionBatch? {
        try await preserveCompletedHistory()
        return try await archive.freezeTranscriptionBatch(configurationFingerprint: speech.configurationFingerprint)
    }

    /// An explicit foreground action hands off one finite batch, without waiting for native inference.
    public func prepareUserContinuationBatch() async throws -> TranscriptionBatch? {
        try await preserveCompletedHistory()
        guard !userPaused else { throw TranscriptionExecutionError.userPaused }
        for _ in 0..<20 where startingManaged || startingRetry {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard !startingManaged, !startingRetry else { throw TranscriptionExecutionError.busy }
        if retryScope != nil {
            retryScope = nil
            retrySources = nil
            automaticWorkAfterRetry = true
        }
        let pauseRevision = lastUserPauseRevision
        startingManaged = true
        defer { startingManaged = false }
        if let execution = managed?.handle {
            guard execution.origin == .foreground, let batch = execution.batchExecution else { throw TranscriptionExecutionError.busy }
            try await stop(execution: execution, reason: .interrupted)
            return try await archive.transcriptionBatch(id: batch.batchID)
        }
        // Include the current automatic claim in the handoff without awaiting native inference.
        let target = captureInvalidationTarget()
        stopCurrentAttempt()
        try await invalidateAttempt(target)
        guard !userPaused, lastUserPauseRevision == pauseRevision else { throw TranscriptionExecutionError.userPaused }
        if let existing = try await archive.activeTranscriptionBatches().first(where: {
            $0.configurationFingerprint == speech.configurationFingerprint && $0.state != .running
        }) {
            return try await archive.resumeTranscriptionBatch(id: existing.id)
        }
        return try await archive.freezeTranscriptionBatch(configurationFingerprint: speech.configurationFingerprint,
                                                          includingUnpreparedAudio: true)
    }

    /// Explicit user action; it does not clear the separate global pause preference.
    public func resumeBatch(id: UUID) async throws -> TranscriptionBatch {
        try await archive.resumeTranscriptionBatch(id: id)
    }

    public func startBatch(id: UUID, origin: TranscriptionBatchOrigin,
                           finiteBudget: Bool = false,
                           onFinished: @escaping @Sendable (TranscriptionExecutionCompletion) -> Void) async throws -> TranscriptionExecutionHandle {
        guard !userPaused else { throw TranscriptionExecutionError.userPaused }
        if origin == .continuedProcessing {
            for _ in 0..<240 where startingManaged || startingRetry {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        guard !startingManaged, !startingRetry else { throw TranscriptionExecutionError.busy }
        startingManaged = true
        defer { startingManaged = false }
        if origin == .continuedProcessing {
            if retryScope != nil {
                retryScope = nil
                retrySources = nil
                automaticWorkAfterRetry = true
                let target = captureInvalidationTarget()
                stopCurrentAttempt()
                try await invalidateAttempt(target)
            }
            if let existing = managed?.handle, existing.origin != .continuedProcessing {
                try await stop(execution: existing, reason: .interrupted)
            }
            if let currentBatch = try? await archive.transcriptionBatch(id: id) {
                if currentBatch.state == .completed {
                    let handle = TranscriptionExecutionHandle(id: UUID(), origin: origin, batchExecution: nil)
                    batchSnapshot = currentBatch
                    publish()
                    onFinished(TranscriptionExecutionCompletion(execution: handle, reason: .completed, failureCode: nil))
                    return handle
                }
                if currentBatch.state == .running, managed == nil, let orphanExecution = currentBatch.execution {
                    _ = try? await archive.finishTranscriptionBatch(execution: orphanExecution, reason: .interrupted)
                } else if currentBatch.state == .paused {
                    _ = try? await archive.resumeTranscriptionBatch(id: id)
                }
            }
        }
        guard managed == nil, retryScope == nil else { throw TranscriptionExecutionError.busy }
        let pauseRevision = lastUserPauseRevision
        let suspensionRevision = lastSceneSuspensionRevision
        let execution = try await archive.beginTranscriptionBatch(id: id, origin: origin)
        #if DEBUG
        await onAdmissionReturned?()
        #endif
        let handle = TranscriptionExecutionHandle(id: execution.executionID, origin: origin, batchExecution: execution)
        let interruption: TranscriptionBatchEndReason?
        if userPaused || lastUserPauseRevision != pauseRevision { interruption = .userPaused }
        else if origin == .foreground && !foregroundContinuationAllowed && (systemSuspended || lastSceneSuspensionRevision != suspensionRevision) { interruption = .interrupted }
        else { interruption = nil }
        // An already-running foreground worker must not adopt an interrupted admission during the snapshot await.
        managed = ManagedTranscriptionExecution(handle: handle, onFinished: onFinished, stopping: interruption)
        finiteBackgroundExecutionID = finiteBudget ? handle.id : nil
        do {
            let initial = try await archive.transcriptionBatch(id: id)
            if managed?.handle == handle { batchSnapshot = initial }
            // A pause/resume pair before adoption must not restart the older user-requested batch.
            if let interruption { try await stop(execution: handle, reason: interruption) }
            else if userPaused || lastUserPauseRevision != pauseRevision { try await stop(execution: handle, reason: .userPaused) }
            else if origin == .foreground && !foregroundContinuationAllowed && (systemSuspended || lastSceneSuspensionRevision != suspensionRevision) {
                try await stop(execution: handle, reason: .interrupted)
            }
            else { requestWork() }
            publish()
            return handle
        } catch {
            let code = failureCode(for: error)
            do { try await persistManagedEnd(handle, reason: .interrupted) }
            catch { completeManaged(handle, reason: .interrupted, failure: "archive_cancel_barrier_failed"); throw error }
            completeManaged(handle, reason: .interrupted, failure: code)
            throw error
        }
    }

    public func hasUnreservedPriorityWork() async -> Bool {
        (try? await archive.hasUnreservedPriorityWork(configurationFingerprint: speech.configurationFingerprint)) ?? false
    }

    public func hasResumableBackgroundWork(excludingBatchID: UUID? = nil) async -> Bool {
        guard !userPaused, managed == nil, !startingManaged, !startingRetry, retryScope == nil else { return false }
        if await hasUnreservedPriorityWork() { return true }
        let fingerprint = speech.configurationFingerprint
        if let batches = try? await archive.activeTranscriptionBatches(),
           batches.contains(where: {
               $0.id != excludingBatchID
                   && $0.configurationFingerprint == fingerprint
                   && ($0.state == .ready || ($0.state == .paused && $0.endReason != .userPaused))
           }) {
            return true
        }
        if let waitState = try? await archive.processingWaitState(configurationFingerprint: fingerprint),
           waitState == .queued {
            return true
        }
        return false
    }

    public func resumeSystemEndedBatchForBackgroundProcessing(excludingBatchID: UUID? = nil) async throws -> UUID? {
        guard !userPaused, managed == nil, !startingManaged, !startingRetry, retryScope == nil else { return nil }
        try await preserveCompletedHistory()
        guard !userPaused, managed == nil, !startingManaged, !startingRetry, retryScope == nil else { return nil }
        guard let existing = try await archive.activeTranscriptionBatches().first(where: {
            $0.id != excludingBatchID
                && $0.configurationFingerprint == speech.configurationFingerprint
                && ($0.state == .ready || ($0.state == .paused && $0.endReason != .userPaused))
        }) else { return nil }
        if existing.state == .paused {
            _ = try await archive.resumeTranscriptionBatch(id: existing.id)
        }
        return existing.id
    }

    public func startBackgroundAutomatic(finiteBudget: Bool = false,
                                         onFinished: @escaping @Sendable (TranscriptionExecutionCompletion) -> Void) async throws -> TranscriptionExecutionHandle {
        guard !userPaused else { throw TranscriptionExecutionError.userPaused }
        guard managed == nil, !startingManaged, !startingRetry, retryScope == nil else { throw TranscriptionExecutionError.busy }
        try await preserveCompletedHistory()
        guard !userPaused else { throw TranscriptionExecutionError.userPaused }
        guard managed == nil, !startingManaged, !startingRetry, retryScope == nil else { throw TranscriptionExecutionError.busy }
        let handle = TranscriptionExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        managed = ManagedTranscriptionExecution(handle: handle, onFinished: onFinished)
        finiteBackgroundExecutionID = finiteBudget ? handle.id : nil
        batchSnapshot = nil
        requestWork()
        publish()
        return handle
    }

    /// Expands priority interleaving on an active batch to include same-day (`Tier 2`) unreserved WAL work
    /// in addition to always-automatic `Tier 0` live speech and `Tier 1` focused recordings.
    public func requestPriorityInterleaving(execution: TranscriptionExecutionHandle) {
        guard managed?.handle == execution, managed?.stopping == nil else { return }
        guard execution.batchExecution != nil else { return }
        managed?.interleavePriorityWork = true
        requestWork()
    }

    /// Signals newly arrived hot live wearable audio so the unified WAL scheduler drains it at the next
    /// bounded step boundary (<0.2 s VAD / <0.8 s ASR) without cancelling in-flight inference.
    public func onHotLiveWorkArrived(foreground _: Bool, ultraHot _: Bool) async {
        if let execution = managed?.handle, execution.batchExecution != nil, managed?.stopping == nil {
            managed?.interleavePriorityWork = true
        }
        hotArrivalCreditBoostPending = true
        requestWork()
    }

    /// Cooperatively yields a foreground batch at the next durable step boundary instead of cancelling mid-inference.
    public func yieldToPriorityWork(execution: TranscriptionExecutionHandle) async throws {
        guard managed?.handle == execution, managed?.stopping == nil else { return }
        guard execution.origin == .foreground, execution.batchExecution != nil else { return }
        if !nativeInFlight && activeWork == nil && pendingClaim == nil {
            try await stop(execution: execution, reason: .interrupted)
        } else {
            managed?.yieldAfterCurrentStep = true
        }
    }

    /// Persists the stop barrier and completes the caller without awaiting a native Speech call.
    public func stop(execution: TranscriptionExecutionHandle, reason: TranscriptionBatchEndReason) async throws {
        if let barrier = stopBarrier, barrier.executionID == execution.id {
            #if DEBUG
            await onStopBoundary?(.joined)
            #endif
            try await barrier.task.value
            #if DEBUG
            await onStopBoundary?(.finished)
            #endif
            return
        }
        guard managed?.handle == execution else { return }
        if reason == .backgroundExpired && execution.origin != .backgroundProcessing { throw TranscriptionExecutionError.invalidOrigin }
        managed?.stopping = reason
        let handoffToForeground = execution.batchExecution == nil && reason == .interrupted && !systemSuspended && !userPaused
        let stopsWorker = !handoffToForeground && (activeExecutionID == execution.id || systemSuspended)
        let target = stopsWorker ? captureInvalidationTarget() : nil
        if stopsWorker { stopCurrentAttempt() }
        let task = Task { try await self.finishStop(execution, reason: reason, target: target, keepWorkerPhase: handoffToForeground) }
        stopBarrier = (execution.id, task)
        try await task.value
        #if DEBUG
        await onStopBoundary?(.finished)
        #endif
    }

    private func finishStop(_ execution: TranscriptionExecutionHandle, reason: TranscriptionBatchEndReason,
                            target: InvalidationTarget?, keepWorkerPhase: Bool = false) async throws {
        #if DEBUG
        await onStopBoundary?(.started)
        #endif
        do {
            if let target { try await invalidateAttempt(target) }
            let persistedReason = try await persistManagedEnd(execution, reason: reason)
            completeManaged(execution, reason: persistedReason, failure: nil, keepWorkerPhase: keepWorkerPhase)
        } catch {
            failureCode = "archive_cancel_barrier_failed"
            completeManaged(execution, reason: reason, failure: failureCode)
            throw error
        }
        requestWork()
    }

    @discardableResult
    private func persistManagedEnd(_ handle: TranscriptionExecutionHandle, reason: TranscriptionBatchEndReason) async throws -> TranscriptionBatchEndReason {
        if let execution = handle.batchExecution {
            let updated = try await archive.finishTranscriptionBatch(execution: execution, reason: reason)
            if managed?.handle == handle { batchSnapshot = updated }
            return updated.endReason ?? reason
        }
        return reason
    }

    private func completeManaged(_ handle: TranscriptionExecutionHandle, reason: TranscriptionBatchEndReason,
                                 failure: String?, keepWorkerPhase: Bool = false) {
        guard let run = managed, run.handle == handle else { return }
        managed = nil
        if finiteBackgroundExecutionID == handle.id { finiteBackgroundExecutionID = nil }
        if let failure { failureCode = failure; phase = .failed }
        else if userPaused { phase = .paused }
        else if systemSuspended { phase = .systemSuspended }
        else if !(keepWorkerPhase && (worker != nil || nativeInFlight)) { phase = .idle }
        publish()
        run.onFinished(TranscriptionExecutionCompletion(execution: handle, reason: reason, failureCode: failure))
    }

    private func refreshBatch(_ handle: TranscriptionExecutionHandle?) async throws {
        guard let handle, let execution = handle.batchExecution else { return }
        let updated = try await archive.transcriptionBatch(id: execution.batchID)
        if managed?.handle == handle { batchSnapshot = updated; publish() }
    }

    /// The deletion coordinator persists Archive's deletion barrier before calling this method.
    public func cancel(sessionID: UUID) async {
        speech.discardPreparedAudio(sessionID: sessionID)
        if failureScope?.sessionID == sessionID { failureScope = nil }
        if activeSessionID != sessionID {
            try? await closeReadingSequences(sessionID: sessionID)
        }
        // A claim can already own audio leases while its returned ticket has no active session yet.
        guard activeSessionID == sessionID || (activeSessionID == nil && worker != nil) else { return }
        restartAfterCancellation = true
        stopCurrentAttempt()
        do { try await invalidateActiveAttempt() }
        catch { failureCode = "archive_cancel_barrier_failed"; restartAfterCancellation = false; publish() }
    }

    private func invalidateActiveAttempt() async throws {
        try await invalidateAttempt(captureInvalidationTarget())
    }

    private func captureInvalidationTarget() -> InvalidationTarget {
        InvalidationTarget(work: activeWork, claim: pendingClaim)
    }

    private func invalidateAttempt(_ target: InvalidationTarget) async throws {
        // A claim owns a durable attempt before its actor await returns to this coordinator.
        // Wait only for that short database operation; native work is never awaited here.
        let work: ActiveWork?
        if let captured = target.work { work = captured }
        else if let captured = target.claim { work = await captured.claimedWork() }
        else { work = nil }
        switch work {
        case .epoch(let ticket): try await archive.invalidateEpochAnalysisAttempt(ticket: ticket)
        case .window(let ticket): try await archive.invalidateTranscriptionWindowAttempt(ticket: ticket)
        case .windows(let tickets):
            for ticket in tickets { try await archive.invalidateTranscriptionWindowAttempt(ticket: ticket) }
        case nil: break
        }
        // The first window remains active while its companion claim crosses
        // the Archive actor. Fence those new attempts before returning the stop.
        if target.work != nil, case .companions(let claim) = target.claim,
           case .success(let tickets) = await claim.result {
            for ticket in tickets { try await archive.invalidateTranscriptionWindowAttempt(ticket: ticket) }
        }
    }

    private func stopCurrentAttempt() {
        attempt?.cancel()
        worker?.cancel()
    }

    public func preserveCompletedHistory() async throws {
        let fingerprint = speech.configurationFingerprint
        if preservedHistoryFingerprint != fingerprint {
            try await archive.upgradeSpeakerProfilesIfNeeded()
            for previous in speech.previousConfigurationFingerprints {
                try await archive.preserveCompletedAnalysis(from: previous, to: fingerprint)
            }
            // Reopen low-volume October 27–28 audio skipped before causal VAD P98 envelope normalization.
            let oct27Interval = DateInterval(start: Date(timeIntervalSince1970: 1_793_102_400),
                                             end: Date(timeIntervalSince1970: 1_793_174_400))
            _ = try await archive.reopenNoSpeechOnce(
                key: "no-speech-review/oct27-28-vad-p98-v1/\(fingerprint)",
                in: oct27Interval,
                configurationFingerprint: fingerprint
            )
            preservedHistoryFingerprint = fingerprint
        }
        // After preservation, so re-planned epochs are not refilled with carried results.
        try await archive.replanRequestedAnalysis(configurationFingerprint: fingerprint)
    }

    private func extractPendingVoiceprintSeedsIfNeeded(limit: Int? = nil) async throws {
        let revision = SpeechEngine.speakerEmbeddingRevision
        var processed = 0
        var updatedVoiceprints = false
        defer {
            if updatedVoiceprints { onVoiceprintUpdated() }
        }
        while canRun {
            if let limit, processed >= limit { break }
            try Task.checkCancellation()
            guard let candidate = try await archive.claimNextVoiceprintSeedCandidate(modelRevision: revision) else { break }
            processed += 1
            let token = SpeechAttempt()
            attempt = token
            nativeInFlight = true
            do {
                let extracted = try await speech.extractCleanVoiceprint(
                    inputs: candidate.inputs.map(speechInput),
                    frames: candidate.frames,
                    attempt: token)
                nativeInFlight = false
                attempt = nil
                try Task.checkCancellation()
                try await archive.completeVoiceprintSeedCandidate(
                    candidate,
                    modelRevision: revision,
                    extracted: extracted.map { ($0.embedding, $0.cleanSeconds) })
                if extracted != nil { updatedVoiceprints = true }
            } catch {
                nativeInFlight = false
                attempt = nil
                try? await archive.releaseVoiceprintSeedCandidate(candidate)
                if error is CancellationError || (error as? SpeechError) == .cancelled { throw error }
                try? await archive.completeVoiceprintSeedCandidate(candidate, modelRevision: revision, extracted: nil)
            }
        }
    }

    private func claimNextWALStep(
        lease: TranscriptionComputeLease,
        inputLease: TranscriptionInputLease?,
        retry: (sessionID: UUID, generation: Int64)?,
        sources: [TimelineAudioSource]?,
        now: Date,
        pacer: inout WALBackfillPacer
    ) async throws -> WALStep {
        let fingerprint = speech.configurationFingerprint

        if let retry {
            let windowClaim = Task { [archive] in
                try await archive.claimTranscriptionWindow(
                    configurationFingerprint: fingerprint,
                    inputLease: inputLease,
                    sessionID: retry.sessionID,
                    expectedGeneration: retry.generation,
                    sources: sources,
                    isolateLocalFailures: false,
                    now: now
                )
            }
            pendingClaim = .window(windowClaim)
            if let ticket = try await windowClaim.value {
                return .transcribeWindow(ticket, source: .retry)
            }
            pendingClaim = nil

            let epochClaim = Task { [archive] in
                try await archive.claimEpochAnalysis(
                    configurationFingerprint: fingerprint,
                    sessionID: retry.sessionID,
                    expectedGeneration: retry.generation,
                    sources: sources,
                    finalizeAvailablePrefixBefore: .distantFuture,
                    isolateLocalFailures: false,
                    now: now
                )
            }
            pendingClaim = .epoch(epochClaim)
            if let ticket = try await epochClaim.value {
                return .prepareEpoch(ticket, source: .retry)
            }
            pendingClaim = nil
            return .none
        }

        guard let execution = lease.managedHandle, let batch = execution.batchExecution else {
            let allowHistorical = lease.historicalWorkAllowed
            let focusedDay = lease.effectiveFocusedDay
            let focusedSessionID = lease.effectiveFocusedSessionID
            let claim = Task { [archive] in
                try await archive.claimAutomaticWork(
                    configurationFingerprint: fingerprint,
                    inputLease: inputLease,
                    allowHistorical: allowHistorical,
                    focusedDay: focusedDay,
                    focusedSessionID: focusedSessionID,
                    now: now
                )
            }
            pendingClaim = .automatic(claim)
            switch try await claim.value {
            case .analysis(let ticket):
                return .prepareEpoch(ticket, source: .automatic)
            case .transcription(let ticket):
                return .transcribeWindow(ticket, source: .automatic)
            case nil:
                pendingClaim = nil
                return .none
            }
        }

        // Unified Omi-style WAL arbitration during active batch backfill:
        // 1. Live wearable speech (`Tier 0`) and user-viewed views (`Tier 1`) automatically
        //    interleave ahead of historical batch items without requiring manual flags.
        // 2. If a continuous Watch epoch has hot-live WAL chunks blocked behind an unanalyzed
        //    batch prefix, one 120 s stateless VAD pass (~0.15 s) prepares that prefix immediately.
        var allowPriorityStep = pacer.canRunPriorityStepFromCredit
        var burstTailHotOnly = false
        if !allowPriorityStep,
           let summary = try? await archive.livePriorityWorkSummary(configurationFingerprint: fingerprint),
           pacer.canExtendHotTailBurst(
               backgroundContinued: lease.isBackgroundContinued,
               summary: (summary.hasHotLiveWork, summary.hotPendingSeconds)
           ) {
            allowPriorityStep = true
            burstTailHotOnly = true
        }

        let today = TimelineDay(Date())
        let hasActiveFocus = lease.hasActiveFocus(today: today)
        let focusedDay = lease.effectiveFocusedDay
        let focusedSessionID = lease.effectiveFocusedSessionID

        if allowPriorityStep {
            let continuedOrigin = execution.origin == .continuedProcessing
            let interleaveSameDay = !continuedOrigin && !burstTailHotOnly && (managed?.interleavePriorityWork == true)
            let focusEligible = !continuedOrigin && !burstTailHotOnly && hasActiveFocus
            let effectiveHotOnly = continuedOrigin || burstTailHotOnly || (!interleaveSameDay && !focusEligible)
            let allowFocusedHistorical = !effectiveHotOnly && lease.historicalWorkAllowed && focusEligible
            let priorityMaxTier = (continuedOrigin || burstTailHotOnly) ? 0 : (interleaveSameDay ? 2 : 1)

            let priorityClaim = Task { [archive] in
                try await archive.claimAutomaticWork(
                    configurationFingerprint: fingerprint,
                    inputLease: inputLease,
                    allowHistorical: allowFocusedHistorical,
                    hotOnly: effectiveHotOnly,
                    focusedDay: focusedDay,
                    focusedSessionID: focusedSessionID,
                    maxTier: priorityMaxTier
                )
            }
            pendingClaim = .automatic(priorityClaim)
            switch try await priorityClaim.value {
            case .analysis(let ticket):
                return .prepareEpoch(ticket, source: .interleavedLivePriority)
            case .transcription(let ticket):
                return .transcribeWindow(ticket, source: .interleavedLivePriority)
            case nil:
                pendingClaim = nil
                let unblockClaim = Task { [archive] in
                    try await archive.claimBatchPrefixBlockingLiveTail(
                        execution: batch,
                        configurationFingerprint: fingerprint,
                        maxStepSeconds: Self.walVADStepSeconds,
                        includeSameDayToday: interleaveSameDay
                    )
                }
                pendingClaim = .epoch(unblockClaim)
                if let prefixTicket = try await unblockClaim.value {
                    return .prepareEpoch(prefixTicket, source: .batchBackfill)
                }
                pendingClaim = nil
                if !burstTailHotOnly {
                    if managed?.handle == execution {
                        managed?.interleavePriorityWork = false
                    }
                    pacer.resetForIdlePriority(backgroundContinued: lease.isBackgroundContinued)
                }
            }
        }

        if hasActiveFocus {
            let tier1WindowClaim = Task { [archive] in
                try await archive.claimTranscriptionWindow(
                    configurationFingerprint: fingerprint,
                    batchExecution: batch,
                    inputLease: inputLease,
                    isolateLocalFailures: true,
                    focusedDay: focusedDay,
                    focusedSessionID: focusedSessionID,
                    maxTier: 1
                )
            }
            pendingClaim = .window(tier1WindowClaim)
            if let ticket = try await tier1WindowClaim.value {
                return .transcribeWindow(ticket, source: .batchBackfill)
            }
            pendingClaim = nil

            let tier1EpochClaim = Task { [archive] in
                try await archive.claimTranscriptionBatchAnalysis(
                    execution: batch,
                    configurationFingerprint: fingerprint,
                    maxStepSeconds: Self.walVADStepSeconds,
                    focusedDay: focusedDay,
                    focusedSessionID: focusedSessionID,
                    maxTier: 1
                )
            }
            pendingClaim = .epoch(tier1EpochClaim)
            if let ticket = try await tier1EpochClaim.value {
                return .prepareEpoch(ticket, source: .batchBackfill)
            }
            pendingClaim = nil
        }

        let batchWindowClaim = Task { [archive] in
            try await archive.claimTranscriptionWindow(
                configurationFingerprint: fingerprint,
                batchExecution: batch,
                inputLease: inputLease,
                isolateLocalFailures: true,
                focusedDay: focusedDay,
                focusedSessionID: focusedSessionID
            )
        }
        pendingClaim = .window(batchWindowClaim)
        if let ticket = try await batchWindowClaim.value {
            return .transcribeWindow(ticket, source: .batchBackfill)
        }
        pendingClaim = nil

        let batchEpochClaim = Task { [archive] in
            try await archive.claimTranscriptionBatchAnalysis(
                execution: batch,
                configurationFingerprint: fingerprint,
                maxStepSeconds: Self.walVADStepSeconds,
                focusedDay: focusedDay,
                focusedSessionID: focusedSessionID
            )
        }
        pendingClaim = .epoch(batchEpochClaim)
        if let ticket = try await batchEpochClaim.value {
            return .prepareEpoch(ticket, source: .batchBackfill)
        }
        pendingClaim = nil

        return .completeBatch(execution, batch)
    }

    private func drain() async -> TranscriptionRunReport {
        let retry = retryScope
        let sources = retrySources
        var prepared = 0, transcribed = 0
        var consecutiveRevisions = 0
        var pacer = WALBackfillPacer(backgroundContinued: computeLease.isBackgroundContinued)
        var finiteBudgetExhausted = false
        // Allow a short edit burst, but stop retrying if a file keeps changing without any committed progress.
        let maximumConsecutiveRevisions = 3
        func monotonicUptimeSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) * 1e-9 }

        do {
            if computeLease.allowsInitialHistoryPreservation {
                try await preserveCompletedHistory()
            }
            if computeLease.allowsInitialVoiceprintExtraction {
                // Process user-confirmed speaker anchors promptly without starving incoming live audio.
                try await extractPendingVoiceprintSeedsIfNeeded(limit: 2)
            }
            while canRun {
                try Task.checkCancellation()
                if let current = managed, current.yieldAfterCurrentStep, current.stopping == nil {
                    let persistedReason = try await persistManagedEnd(current.handle, reason: .interrupted)
                    if managed?.stopping == nil {
                        completeManaged(current.handle, reason: persistedReason, failure: nil, keepWorkerPhase: true)
                    }
                    activeExecutionID = nil
                    continue
                }
                let preBudgetLease = computeLease
                if (prepared + transcribed) > 0,
                   preBudgetLease.hasFiniteBudget,
                   let remainingFiniteBackgroundSeconds,
                   let remaining = await remainingFiniteBackgroundSeconds(),
                   remaining.isFinite,
                   remaining < preBudgetLease.finiteStopThreshold(transcribedWindows: transcribed) {
                    if let run = managed, run.stopping == nil, run.handle.id == finiteBackgroundExecutionID {
                        finiteBudgetExhausted = true
                        let persistedReason = try await persistManagedEnd(run.handle, reason: .backgroundExpired)
                        if managed?.stopping == nil {
                            completeManaged(run.handle, reason: persistedReason, failure: nil)
                        }
                        activeExecutionID = nil
                        break
                    } else if let run = managed, run.stopping == nil, run.handle.origin == .foreground,
                              systemSuspended, foregroundContinuationAllowed {
                        finiteBudgetExhausted = true
                        foregroundContinuationAllowed = false
                        let persistedReason = try await persistManagedEnd(run.handle, reason: .interrupted)
                        if managed?.stopping == nil {
                            completeManaged(run.handle, reason: persistedReason, failure: nil)
                        }
                        activeExecutionID = nil
                        break
                    } else if managed == nil, systemSuspended, foregroundContinuationAllowed {
                        finiteBudgetExhausted = true
                        foregroundContinuationAllowed = false
                        phase = userPaused ? .paused : .systemSuspended
                        break
                    }
                }

                try Task.checkCancellation()
                guard canRun else { break }
                let lease = computeLease
                if hotArrivalCreditBoostPending {
                    hotArrivalCreditBoostPending = false
                    pacer.noteHotLiveArrival(backgroundContinued: lease.isBackgroundContinued)
                }
                requested = false
                let execution = lease.managedHandle
                activeExecutionID = execution?.id
                let inputLease = readingSequences.first?.lease
                let stepStartedAt = Date()

                let step = try await claimNextWALStep(
                    lease: lease,
                    inputLease: inputLease,
                    retry: retry,
                    sources: sources,
                    now: stepStartedAt,
                    pacer: &pacer
                )

                switch step {
                case .prepareEpoch(let ticket, let source):
                    #if DEBUG
                    await onClaimReturned?(.analysis, ticket.sessionID)
                    #endif
                    let prepStart = monotonicUptimeSeconds()
                    switch try await prepare(ticket) {
                    case .committed:
                        prepared += 1
                        consecutiveRevisions = 0
                    case .superseded:
                        consecutiveRevisions += 1
                        guard consecutiveRevisions < maximumConsecutiveRevisions else { throw TranscriptionCoordinatorError.repeatedRevisions }
                    case .deferred:
                        break
                    }
                    let prepElapsed = monotonicUptimeSeconds() - prepStart
                    if source == .interleavedLivePriority {
                        pacer.recordPriorityPrepStep(elapsed: prepElapsed)
                    } else if source == .batchBackfill {
                        pacer.refillAfterBackfillStep(elapsed: prepElapsed, backgroundContinued: computeLease.isBackgroundContinued)
                        try await refreshBatch(execution)
                    }
                    continue

                case .transcribeWindow(let ticket, let source):
                    #if DEBUG
                    await onClaimReturned?(.transcription, ticket.window.sessionID)
                    #endif
                    let stepStart = monotonicUptimeSeconds()
                    let isInterleavedPriority = source == .interleavedLivePriority
                    switch try await transcribe(ticket, interleavedPriority: isInterleavedPriority, preferSingleWindow: transcribed == 0) {
                    case .committed:
                        transcribed += lastTranscribedWindowCount
                        publish()
                        consecutiveRevisions = 0
                    case .superseded:
                        consecutiveRevisions += 1
                        guard consecutiveRevisions < maximumConsecutiveRevisions else { throw TranscriptionCoordinatorError.repeatedRevisions }
                    case .deferred:
                        break
                    }
                    let stepElapsed = monotonicUptimeSeconds() - stepStart
                    if isInterleavedPriority {
                        pacer.recordPriorityWindowStep(elapsed: stepElapsed)
                    } else if source == .batchBackfill {
                        pacer.refillAfterBackfillStep(elapsed: stepElapsed, backgroundContinued: computeLease.isBackgroundContinued)
                        try await refreshBatch(execution)
                    }
                    continue

                case .completeBatch(let batchHandle, let batch):
                    try Task.checkCancellation()
                    if managed?.handle != batchHandle { continue }
                    try await closeReadingSequence()
                    try Task.checkCancellation()
                    let reason: TranscriptionBatchEndReason
                    do {
                        reason = try await persistManagedEnd(batchHandle, reason: .completed)
                    } catch TranscriptionBatchError.incomplete {
                        _ = try? await archive.deferUnclaimableBatchItems(
                            execution: batch,
                            configurationFingerprint: speech.configurationFingerprint
                        )
                        do {
                            reason = try await persistManagedEnd(batchHandle, reason: .completed)
                        } catch TranscriptionBatchError.incomplete {
                            performanceLogger.error("Batch \(batch.batchID, privacy: .public) still had unclaimable items; suspending as systemEndedUnknown so automatic transcription can proceed")
                            reason = try await persistManagedEnd(batchHandle, reason: .systemEndedUnknown)
                        }
                    }
                    // A stop that arrived during the Archive await owns completion after its barrier.
                    if managed?.stopping == nil { completeManaged(batchHandle, reason: reason, failure: nil) }
                    activeExecutionID = nil
                    continue

                case .none:
                    break
                }

                try await closeReadingSequence()
                try Task.checkCancellation()
                if managed?.handle != execution { continue }
                if requested { continue }
                let waiting = try await archive.processingWaitState(configurationFingerprint: speech.configurationFingerprint, sessionID: retry?.sessionID)
                try Task.checkCancellation()
                if !canRun { break }
                if requested { continue }
                if let retry {
                    let selected = try await archive.recordingSummary(sessionID: retry.sessionID)
                    guard selected.generation == retry.generation else { throw ArchiveError.staleSource }
                    var selectedComplete = false
                    if let sources {
                        selectedComplete = try await archive.timelineRetryIsComplete(sources: sources,
                            configurationFingerprint: speech.configurationFingerprint)
                    }
                    try Task.checkCancellation()
                    if selectedComplete { phase = .idle }
                    else {
                        switch selected.transcriptionState {
                        case .pending, .processing: applyWaitingState(waiting)
                        case .failed:
                            phase = .failed
                            failedSessionID = retry.sessionID
                            failureCode = "recording_audio_unavailable"
                        default: phase = .idle
                        }
                    }
                } else {
                    applyWaitingState(waiting)
                }

                // Omi-style conversation silence boundary: if an open trailing utterance is waiting
                // for context and no further WAL chunk arrives within `staleOpenTailSeconds` (180 s),
                // wake automatically at the exact wall-clock deadline to seal `.receivedSnapshot`.
                if phase == .waitingForContext,
                   execution == nil,
                   canRun,
                   !computeLease.hasFiniteBudget,
                   let finalizeAt = try? await archive.nextOpenTailFinalizationDate(
                       configurationFingerprint: speech.configurationFingerprint,
                       sessionID: retry?.sessionID,
                       allowHistorical: retry != nil || historicalWorkAllowed,
                       now: stepStartedAt
                   ) {
                    try Task.checkCancellation()
                    if requested || managed?.handle != execution { continue }
                    scheduleWake(at: finalizeAt)
                }

                if retry == nil, computeLease.allowsIdleVoiceprintExtraction, canRun {
                    try await extractPendingVoiceprintSeedsIfNeeded()
                    if requested { continue }
                }
                if let execution, execution.batchExecution == nil {
                    completeManaged(execution, reason: .completed, failure: nil)
                    activeExecutionID = nil
                }
                break
            }
        } catch is CancellationError {
            phase = userPaused ? .paused : (systemSuspended ? .systemSuspended : .idle)
        } catch SpeechError.cancelled {
            phase = userPaused ? .paused : (systemSuspended ? .systemSuspended : .idle)
        } catch {
            phase = .failed
            failedSessionID = lastAttemptedSessionID ?? retry?.sessionID
            failureCode = failureCode(for: error)
            if let handle = managed?.handle, activeExecutionID == handle.id, managed?.stopping == nil {
                do { try await persistManagedEnd(handle, reason: .interrupted) }
                catch { failureCode = "archive_cancel_barrier_failed" }
                completeManaged(handle, reason: .interrupted, failure: failureCode)
            }
        }
        do {
            try await closeReadingSequence()
        } catch { phase = .failed; failureCode = "archive_reader_cleanup_failed" }
        speech.discardPreparedAudio()
        activeSessionID = nil
        attempt = nil
        activeWork = nil
        pendingClaim = nil
        activeExecutionID = nil
        worker = nil
        if finiteBudgetExhausted && systemSuspended {
            foregroundContinuationAllowed = false
            if phase != .failed && phase != .paused { phase = .systemSuspended }
        }
        publish()
        let report = TranscriptionRunReport(snapshot: snapshot(), preparedBatches: prepared, transcribedWindows: transcribed)
        retryScope = nil
        retrySources = nil
        if automaticWorkAfterRetry {
            automaticWorkAfterRetry = false
            requested = true
        }
        if finiteBudgetExhausted && systemSuspended && managed == nil {
            restartAfterCancellation = false
            return report
        }
        if restartAfterCancellation || managed != nil || (requested && canRun && phase != .failed) {
            restartAfterCancellation = false
            requestWork()
        } else if requested && canRun && phase == .failed {
            requested = false
            retryWakeTask?.cancel()
            retryWakeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await self?.requestWork()
            }
        }
        return report
    }

    private func prepare(_ claimed: EpochAnalysisTicket) async throws -> WorkOutcome {
        var ticket = claimed
        let token = SpeechAttempt(id: ticket.attemptID)
        activeSessionID = ticket.sessionID
        lastAttemptedSessionID = ticket.sessionID
        activeWork = .epoch(ticket)
        pendingClaim = nil
        attempt = token
        do {
            try Task.checkCancellation()
            ticket = try await archive.withAnalysisReplayPrefix(
                ticket,
                includingRecognitionContext: speech.continuousArchive
            )
            activeWork = .epoch(ticket)
            try Task.checkCancellation()
            try token.checkCancellation()
            phase = .preparing
            nativeInFlight = true
            publish()
            let result = try await speech.prepare(
                inputs: ticket.inputs.map(speechInput),
                resume: ticket.checkpoint.map(speechCheckpoint),
                boundary: ticket.boundary,
                replayOrigin: ticket.replayOrigin,
                attempt: token
            )
            nativeInFlight = false
            try Task.checkCancellation()
            try token.checkCancellation()
            try await archive.commitAnalysisBatch(
                ticket: ticket,
                windows: result.windows.map(archiveWindow),
                analyzedCoverage: result.analyzedCoverage,
                noSpeechCoverage: result.noSpeechCoverage,
                checkpoint: result.checkpoint.map(archiveCheckpoint),
                waitingForMoreAudio: result.waitingForMoreAudio,
                continuing: false
            )
            completedPreparations += 1
            activeSessionID = nil
            lastAttemptedSessionID = nil
            attempt = nil
            activeWork = nil
            publish()
            return .committed
        } catch {
            nativeInFlight = false
            // Native readers have returned before their original-file leases are released.
            let isolated = shouldLocateFailure(error) && retryScope == nil ? localFailureCode(error) : nil
            if let isolated { try await archive.deferEpochAnalysis(ticket: ticket, code: isolated) }
            else { try await archive.cancelEpochAnalysis(ticket: ticket) }
            activeSessionID = nil
            attempt = nil
            activeWork = nil
            if try await supersededByRevision(error, sessionID: ticket.sessionID, generation: ticket.expectedGeneration) {
                lastAttemptedSessionID = nil
                return .superseded
            }
            if shouldLocateFailure(error), let first = ticket.inputs.first?.envelope.manifest,
               let last = ticket.inputs.last?.envelope.manifest {
                let from = max(first.frames.start, ticket.checkpoint?.sourceFrame ?? first.frames.start)
                let through = min(last.frames.end, ticket.boundary.endFrame ?? .max)
                if through > from {
                    failureScope = TranscriptionFailureScope(sessionID: ticket.sessionID, epochID: ticket.epochID,
                        generation: ticket.expectedGeneration, configurationFingerprint: ticket.configurationFingerprint,
                        frames: try FrameRange(start: from, count: through - from), stage: .analysis,
                        reason: .init(code: failureCode(for: error)))
                }
            }
            if isolated != nil { lastAttemptedSessionID = nil; return .deferred }
            throw error
        }
    }

    private func transcribe(_ ticket: TranscriptionWindowTicket, interleavedPriority: Bool = false,
                            preferSingleWindow: Bool = false) async throws -> WorkOutcome {
        let token = SpeechAttempt(id: ticket.attemptID)
        var resultCommitted = false
        var tickets = [ticket]
        var committedIDs = Set<String>()
        lastTranscribedWindowCount = 0
        activeSessionID = ticket.window.sessionID
        lastAttemptedSessionID = ticket.window.sessionID
        activeWork = .window(ticket)
        pendingClaim = nil
        attempt = token
        do {
            try Task.checkCancellation()
            let hotWindow = (try? await archive.isHotLiveWindow(ticket.window)) ?? false
            let isHotLive = interleavedPriority || hotWindow
            if let existingIndex = readingSequences.firstIndex(where: {
                $0.lease.contains(ticket) && ticket.window.modelCoreFrames.start >= $0.coreEnd
            }) {
                if existingIndex != 0 {
                    let reused = readingSequences.remove(at: existingIndex)
                    readingSequences.insert(reused, at: 0)
                }
            } else {
                // Close any rewound/stale sequence on the same epoch anchor, then bound LRU warm readers to 2
                // (1 live Watch epoch + 1 historical batch epoch) so 60 s Watch interjections never force prefix re-resampling.
                try await closeReadingSequences {
                    $0.lease.epochID == ticket.window.epochID && $0.lease.analysisAnchor == ticket.window.analysisAnchor
                }
                while readingSequences.count >= 2, let evicted = readingSequences.popLast() {
                    await speech.close(evicted.decoder)
                    try await archive.releaseTranscriptionInputLease(evicted.lease)
                }
                let lease = try await archive.acquireTranscriptionInputLease(ticket: ticket)
                do {
                    let decoder = try speech.makeTranscriptionSequence(inputs: lease.inputs.map(speechInput), anchor: lease.analysisAnchor)
                    readingSequences.insert(ReadingSequenceEntry(lease: lease, decoder: decoder, coreEnd: 0), at: 0)
                } catch {
                    try await archive.releaseTranscriptionInputLease(lease)
                    throw error
                }
            }
            try Task.checkCancellation()
            guard let sequence = readingSequences.first else { throw SpeechError.incompatibleWindow }
            let allowCompanionBatching = !preferSingleWindow && computeLease.allowsCompanionBatching(
                isHotLive: isHotLive,
                backgroundBudget: speech.backgroundBudget
            )
            let windowBatchLimit = speech.coordinatorWindowBatchSize
            if allowCompanionBatching, retryScope == nil, !batchDecodeFailed, windowBatchLimit > 1 {
                let companions = Task { [archive, limit = windowBatchLimit] in
                    try await archive.claimCompanionWindows(after: ticket, inputLease: sequence.lease, maximumCount: limit)
                }
                pendingClaim = .companions(companions)
                tickets += try await companions.value
                activeWork = .windows(tickets)
                pendingClaim = nil
                try Task.checkCancellation()
                guard tickets.allSatisfy({ sequence.lease.contains($0) }) else { throw SpeechError.incompatibleWindow }
            }
            phase = .transcribing
            nativeInFlight = true
            publish()
            if let prototypes = try? await archive.enrolledSpeakerPrototypes() {
                speech.setEnrolledSpeakers(prototypes)
            }
            let results = try await speech.transcribe(windows: tickets.map { speechWindow($0.window) },
                sequence: sequence.decoder, attempt: token)
            nativeInFlight = false
            try Task.checkCancellation()
            try token.checkCancellation()
            guard results.count == tickets.count else { throw SpeechError.incompatibleWindow }
            let commitStarted = DispatchTime.now().uptimeNanoseconds
            var batchCommits: [ArchiveStore.WindowTranscriptCommit] = []
            batchCommits.reserveCapacity(tickets.count)
            var inMemoryPrevious: (endFrame: Int64, payload: (result: SpeechRecognition, window: SpeechWindow)?)?
            for (current, result) in zip(tickets, results) {
                try Task.checkCancellation()
                try token.checkCancellation()
                guard result.windowID == current.window.id,
                      result.configurationFingerprint == current.window.configurationFingerprint else { throw SpeechError.incompatibleWindow }
                var previous: (result: SpeechRecognition, window: SpeechWindow)?
                if speech.continuousArchive {
                    if let prev = inMemoryPrevious, prev.endFrame == current.window.coreFrames.start {
                        previous = prev.payload
                    } else if let saved = try await archive.precedingWindowResult(for: current),
                              let recognition = try? WireJSON.decode(SpeechRecognition.self, from: saved.rawResult) {
                        previous = (recognition, speechWindow(saved.window))
                    }
                }
                let window = speechWindow(current.window)
                if let failure = result.speakerFailure {
                    performanceLogger.error("Speaker attribution incomplete: \(failure, privacy: .public), window=\(result.windowID, privacy: .public)")
                }
                let text = speech.archiveText(result, window: window, after: previous)
                let hasWords = !text.unicodeScalars.allSatisfy {
                    CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).contains($0)
                }
                inMemoryPrevious = (
                    endFrame: current.window.coreFrames.end,
                    payload: hasWords ? (result, window) : nil
                )
                batchCommits.append(ArchiveStore.WindowTranscriptCommit(
                    ticket: current,
                    text: text,
                    rawResult: try WireJSON.encode(result),
                    speakerParts: try result.speakerParts(text: text, window: window)
                ))
            }
            _ = try await archive.commitWindowTranscripts(batchCommits)
            for current in tickets {
                committedIDs.insert(current.window.id)
                lastTranscribedWindowCount += 1
                completedWindows += 1
            }
            if let lastTicket = tickets.last,
               let index = readingSequences.firstIndex(where: { $0.decoder === sequence.decoder }) {
                readingSequences[index].coreEnd = lastTicket.window.modelCoreFrames.end
            }
            let committedAt = DispatchTime.now().uptimeNanoseconds
            resultCommitted = true
            activeSessionID = nil
            attempt = nil
            activeWork = nil
            performanceLogger.debug("Transcript postprocessing: windows=\(results.count), commitSeconds=\(Double(committedAt - commitStarted) / 1e9)")
            lastAttemptedSessionID = nil
            return .committed
        } catch {
            nativeInFlight = false
            // A model batch failure is retried as individual windows, so one bad
            // input cannot hold its healthy neighbour or cause endless batch retries.
            let splitBatch = !resultCommitted && tickets.count > 1
                && shouldLocateFailure(error) && windowFailureCode(error) != nil
            if splitBatch { batchDecodeFailed = true }
            let isolated = !resultCommitted && !splitBatch && shouldLocateFailure(error)
                && retryScope == nil ? windowFailureCode(error) : nil
            for current in tickets where !committedIDs.contains(current.window.id) {
                if let isolated { try await archive.deferTranscriptionWindow(ticket: current, code: isolated) }
                else { try await archive.cancelTranscriptionWindow(ticket: current) }
            }
            try await closeReadingSequences(epochID: ticket.window.epochID)
            activeSessionID = nil
            attempt = nil
            activeWork = nil
            if splitBatch { lastAttemptedSessionID = nil; return .deferred }
            if try await supersededByRevision(error, sessionID: ticket.window.sessionID, generation: ticket.expectedGeneration) {
                lastAttemptedSessionID = nil
                return .superseded
            }
            if shouldLocateFailure(error) {
                failureScope = TranscriptionFailureScope(sessionID: ticket.window.sessionID, epochID: ticket.window.epochID,
                    generation: ticket.expectedGeneration, configurationFingerprint: ticket.window.configurationFingerprint,
                    frames: ticket.window.coreFrames, stage: .transcription, reason: .init(code: failureCode(for: error)))
            }
            if isolated != nil { lastAttemptedSessionID = nil; return .deferred }
            throw error
        }
    }

    private func closeReadingSequence() async throws {
        try await closeReadingSequences { _ in true }
    }

    private func closeReadingSequences(sessionID: UUID) async throws {
        try await closeReadingSequences { $0.lease.sessionID == sessionID }
    }

    private func closeReadingSequences(epochID: UUID) async throws {
        try await closeReadingSequences { $0.lease.epochID == epochID }
    }

    private func closeReadingSequences(where predicate: (ReadingSequenceEntry) -> Bool) async throws {
        var retained: [ReadingSequenceEntry] = []
        var closing: [ReadingSequenceEntry] = []
        for entry in readingSequences {
            if predicate(entry) { closing.append(entry) }
            else { retained.append(entry) }
        }
        readingSequences = retained
        var firstError: (any Error)?
        for sequence in closing {
            await speech.close(sequence.decoder)
            do { try await archive.releaseTranscriptionInputLease(sequence.lease) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    private func supersededByRevision(_ error: any Error, sessionID: UUID, generation: Int64) async throws -> Bool {
        guard let archiveError = error as? ArchiveError, archiveError == .staleAttempt else { return false }
        try Task.checkCancellation()
        let current = try await archive.readTranscript(sessionID: sessionID)
        try Task.checkCancellation()
        guard canRun else { throw SpeechError.cancelled }
        return current.generation > generation
    }

    private func applyWaitingState(_ state: ProcessingWaitState) {
        switch state {
        case .idle: phase = .idle
        case .queued: phase = .queued
        case .awaitingAudio: phase = .waitingForAudio
        case .awaitingContext: phase = .waitingForContext
        case .unavailableAudio: phase = .audioUnavailable
        case .retryScheduled(let date):
            phase = .waitingForRetry
            scheduleWake(at: date, minimumDelay: 1)
        }
    }

    /// Bridges monotonic `Task.sleep` to wall-clock `Date` without arbitrary fudge constants:
    /// if `ContinuousClock` wakes slightly before `Date() >= targetDate`, it sleeps the exact
    /// residual delta so downstream `Date`-based SQLite predicates (`<=` / `>`) partition cleanly.
    private func scheduleWake(at targetDate: Date, minimumDelay: TimeInterval = 0) {
        retryWakeTask?.cancel()
        retryWakeTask = Task { [weak self] in
            if minimumDelay > 0 {
                let initial = max(minimumDelay, targetDate.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(initial)) } catch { return }
            }
            while !Task.isCancelled {
                let remaining = targetDate.timeIntervalSinceNow
                guard remaining > 0 else { break }
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.requestWork()
        }
    }

    private func publish() {
        if !canRun { retryWakeTask?.cancel(); retryWakeTask = nil }
        onStateChanged(snapshot())
    }

    private func localFailureCode(_ error: any Error) -> ProcessingFailureCode? {
        if let error = error as? SpeechNativeFailure, error.stage != .load { return .recognition }
        if let error = error as? SpeechError {
            switch error {
            case .invalidAudio, .inputGap: return .invalidAudio
            case .missingAudio: return .audioUnavailable
            case .audioRead: return .audioRead
            case .nativeResult: return .recognition
            default: return nil
            }
        }
        if let error = error as? ArchiveError, case .missingRecording = error { return .audioUnavailable }
        if let error = error as? CocoaError, [.fileReadCorruptFile, .fileReadNoSuchFile, .fileReadNoPermission].contains(error.code) { return .audioRead }
        return nil
    }

    /// A window the planner cannot rebuild fails the same way on every attempt. Defer only that
    /// window, so it cannot end the drain for the healthy windows behind it.
    private func windowFailureCode(_ error: any Error) -> ProcessingFailureCode? {
        if (error as? SpeechError) == .incompatibleWindow { return .recognition }
        return localFailureCode(error)
    }

    private func shouldLocateFailure(_ error: any Error) -> Bool {
        !Task.isCancelled && canRun && !(error is CancellationError) && (error as? SpeechError) != .cancelled
    }

    private func failureCode(for error: any Error) -> String {
        if let local = localFailureCode(error) { return local.rawValue }
        if error is SpeechNativeFailure { return "speech_model_load_failed" }
        if error is TranscriptionCoordinatorError { return "transcript_repeatedly_revised" }
        if error is ArchiveError { return "archive_operation_failed" }
        if let error = error as? SpeechError { return "speech_" + error.diagnosticCode }
        if error is CocoaError { return "local_file_operation_failed" }
        return "transcription_operation_failed"
    }
}

#if DEBUG
enum TranscriptionClaimKind: Sendable, Equatable { case analysis, transcription }
enum TranscriptionStopBoundary: Sendable { case started, joined, finished }
#endif

private enum WALStep {
    case prepareEpoch(EpochAnalysisTicket, source: WALStepSource)
    case transcribeWindow(TranscriptionWindowTicket, source: WALStepSource)
    case completeBatch(TranscriptionExecutionHandle, TranscriptionBatchExecution)
    case none
}

private enum WALStepSource: Equatable {
    case automatic
    case interleavedLivePriority
    case batchBackfill
    case retry
}

private enum ActiveWork: Sendable {
    case epoch(EpochAnalysisTicket), window(TranscriptionWindowTicket), windows([TranscriptionWindowTicket])
}

private struct InvalidationTarget: Sendable {
    let work: ActiveWork?
    let claim: PendingClaim?
}

private enum PendingClaim: Sendable {
    case automatic(Task<AutomaticProcessingWork?, Error>)
    case epoch(Task<EpochAnalysisTicket?, Error>)
    case window(Task<TranscriptionWindowTicket?, Error>)
    case companions(Task<[TranscriptionWindowTicket], Error>)

    func claimedWork() async -> ActiveWork? {
        // The drain still receives and reports a failed claim; a failed claim owns no attempt to invalidate.
        switch self {
        case .automatic(let task):
            if case .success(let work?) = await task.result {
                switch work {
                case .analysis(let ticket): return .epoch(ticket)
                case .transcription(let ticket): return .window(ticket)
                }
            }
        case .epoch(let task):
            if case .success(let ticket?) = await task.result { return .epoch(ticket) }
        case .window(let task):
            if case .success(let ticket?) = await task.result { return .window(ticket) }
        case .companions(let task):
            if case .success(let tickets) = await task.result { return .windows(tickets) }
        }
        return nil
    }
}

private struct ReadingSequenceEntry {
    let lease: TranscriptionInputLease
    let decoder: SpeechTranscriptionSequence
    var coreEnd: Int64
}

private struct ManagedTranscriptionExecution {
    let handle: TranscriptionExecutionHandle
    let onFinished: @Sendable (TranscriptionExecutionCompletion) -> Void
    var stopping: TranscriptionBatchEndReason?
    var yieldAfterCurrentStep = false
    var interleavePriorityWork = false
}

private enum TranscriptionCoordinatorError: Error { case repeatedRevisions }
private enum WorkOutcome { case committed, superseded, deferred }

private struct Preferences: Codable { let userPaused: Bool }

private func speechInput(_ input: ArchivedAudioInput) -> SpeechAudioInput {
    SpeechAudioInput(envelope: input.envelope, audioURL: input.audioURL)
}

private func speechCheckpoint(_ checkpoint: ArchiveCheckpoint) -> SpeechCheckpoint {
    SpeechCheckpoint(sessionID: checkpoint.sessionID, epochID: checkpoint.epochID,
                     sourceFrame: checkpoint.sourceFrame, configurationFingerprint: checkpoint.configurationFingerprint)
}

private func archiveCheckpoint(_ checkpoint: SpeechCheckpoint) -> ArchiveCheckpoint {
    ArchiveCheckpoint(sessionID: checkpoint.sessionID, epochID: checkpoint.epochID,
                      sourceFrame: checkpoint.sourceFrame, configurationFingerprint: checkpoint.configurationFingerprint)
}

private func archiveWindow(_ window: SpeechWindow) -> ArchiveAnalysisWindow {
    ArchiveAnalysisWindow(id: window.id, sessionID: window.sessionID, epochID: window.epochID,
                          analysisAnchor: window.analysisAnchor, coreFrames: window.coreFrames, contextFrames: window.contextFrames,
                          modelCoreFrames: window.modelCoreFrames, modelContextFrames: window.modelContextFrames,
                          sources: window.sources.map { ArchiveWindowSource(chunkID: $0.chunkID, manifestSHA256: $0.manifestSHA256,
                                                                           audioSHA256: $0.audioSHA256, sourceFrames: $0.sourceFrames) },
                          replayInputManifestHashes: window.replayInputManifestHashes,
                          configurationFingerprint: window.configurationFingerprint)
}

private func speechWindow(_ window: ArchiveAnalysisWindow) -> SpeechWindow {
    SpeechWindow(id: window.id, sessionID: window.sessionID, epochID: window.epochID,
                 analysisAnchor: window.analysisAnchor, coreFrames: window.coreFrames, contextFrames: window.contextFrames,
                 modelCoreFrames: window.modelCoreFrames, modelContextFrames: window.modelContextFrames,
                 sources: window.sources.map { SpeechWindowSource(chunkID: $0.chunkID, manifestSHA256: $0.manifestSHA256,
                                                                 audioSHA256: $0.audioSHA256, sourceFrames: $0.sourceFrames) },
                 replayInputManifestHashes: window.replayInputManifestHashes,
                 configurationFingerprint: window.configurationFingerprint)
}
