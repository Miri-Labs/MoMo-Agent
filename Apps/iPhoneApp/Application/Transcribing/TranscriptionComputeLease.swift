import Foundation
import MoMoArchive
import MoMoContracts
import MoMoSpeech

/// Pure, zero-await state machine unifying all iOS foreground/background execution grants,
/// resource constraints, and UI focus rules for WAL transcription scheduling.
struct TranscriptionComputeLease: Sendable, Equatable {
    enum GrantKind: Sendable, Equatable {
        case none
        case foregroundAutomatic
        case sceneContinuationAutomatic
        case foregroundBatch(UUID)
        case sceneContinuationBatch(UUID)
        case backgroundAutomatic(UUID, finiteBudget: Bool)
        case backgroundBatch(UUID, finiteBudget: Bool)
        case continuedProcessingBatch(UUID, backgrounded: Bool, finiteBudget: Bool)
    }

    let userPaused: Bool
    let systemSuspended: Bool
    let foregroundContinuationAllowed: Bool
    let startingManagedWithoutHandle: Bool
    let managedHandle: TranscriptionExecutionHandle?
    let managedStopping: Bool
    let finiteBackgroundExecutionID: UUID?
    let historicalWorkAllowed: Bool
    let historicalResourceConstraint: TranscriptionResourceConstraint?
    let focusedDay: TimelineDay?
    let focusedSessionID: UUID?

    var grant: GrantKind {
        guard !userPaused else { return .none }
        if startingManagedWithoutHandle && managedHandle == nil { return .none }
        if let handle = managedHandle {
            guard !managedStopping else { return .none }
            let isFinite = finiteBackgroundExecutionID == handle.id && finiteBackgroundExecutionID != nil
            switch handle.origin {
            case .foreground:
                if !systemSuspended { return .foregroundBatch(handle.id) }
                if foregroundContinuationAllowed { return .sceneContinuationBatch(handle.id) }
                return .none
            case .backgroundProcessing:
                if handle.batchExecution != nil {
                    return .backgroundBatch(handle.id, finiteBudget: isFinite)
                }
                return .backgroundAutomatic(handle.id, finiteBudget: isFinite)
            case .continuedProcessing:
                return .continuedProcessingBatch(handle.id, backgrounded: systemSuspended, finiteBudget: isFinite)
            }
        }
        if !systemSuspended { return .foregroundAutomatic }
        if foregroundContinuationAllowed { return .sceneContinuationAutomatic }
        return .none
    }

    var canRun: Bool {
        grant != .none
    }

    var isContinuedProcessing: Bool {
        if case .continuedProcessingBatch = grant { return true }
        return false
    }

    var isBackgroundContinued: Bool {
        if case .continuedProcessingBatch(_, let backgrounded, _) = grant { return backgrounded }
        return false
    }

    var hasFiniteBudget: Bool {
        switch grant {
        case .sceneContinuationAutomatic, .sceneContinuationBatch:
            return true
        case .backgroundAutomatic(_, let finite),
             .backgroundBatch(_, let finite),
             .continuedProcessingBatch(_, _, let finite):
            return finite
        case .none, .foregroundAutomatic, .foregroundBatch:
            return false
        }
    }

    func finiteStopThreshold(transcribedWindows: Int) -> TimeInterval {
        transcribedWindows > 0 ? 10 : 6
    }

    var effectiveFocusedDay: TimelineDay? {
        systemSuspended ? nil : focusedDay
    }

    var effectiveFocusedSessionID: UUID? {
        systemSuspended ? nil : focusedSessionID
    }

    func hasActiveFocus(today: TimelineDay) -> Bool {
        (effectiveFocusedDay != nil && effectiveFocusedDay != today) || effectiveFocusedSessionID != nil
    }

    var allowsInitialHistoryPreservation: Bool {
        managedHandle?.batchExecution == nil || managedHandle?.origin == .foreground
    }

    var allowsInitialVoiceprintExtraction: Bool {
        !systemSuspended && !hasFiniteBudget && (managedHandle == nil || managedHandle?.origin == .foreground)
    }

    var allowsIdleVoiceprintExtraction: Bool {
        guard !hasFiniteBudget else { return false }
        return managedHandle == nil
            || managedHandle?.origin == .foreground
            || managedHandle?.origin == .backgroundProcessing
    }

    func allowsCompanionBatching(isHotLive: Bool, backgroundBudget: SpeechBackgroundBudget) -> Bool {
        guard !isHotLive, !hasFiniteBudget else { return false }
        let allowForeground = !systemSuspended
            && (managedHandle == nil
                || managedHandle?.origin == .foreground
                || managedHandle?.origin == .continuedProcessing)
        let allowBackground = backgroundBudget != .standard
            && backgroundBudget != .finiteBackgroundTask
            && finiteBackgroundExecutionID == nil
            && (managedHandle?.origin == .backgroundProcessing
                || managedHandle?.origin == .continuedProcessing)
        return allowForeground || allowBackground
    }
}

/// Omi-inspired paced WAL backfill arbiter:
/// - Hot live wearable speech (`Tier 0`) drains immediately in a single burst (up to 90 s tail)
///   so active conversations never strand their trailing utterance behind offline backlog.
/// - Sustained live streams and multi-hour offline backfills share wall-clock compute 4:1 via
///   deficit round-robin credit without ever cancelling in-flight CoreML / ONNX steps.
struct WALBackfillPacer: Sendable {
    static let maxConsecutivePriorityPrepSteps = 24
    static let burstTailMaxPendingSeconds: Double = 90.0
    static let burstTailMaxElapsedSeconds: Double = 18.0

    private(set) var priorityCreditSeconds: Double
    private(set) var priorityBurstElapsedSeconds: Double = 0
    private(set) var consecutivePriorityPrepSteps: Int = 0

    init(backgroundContinued: Bool) {
        self.priorityCreditSeconds = backgroundContinued ? 8.0 : 12.0
    }

    mutating func resetForIdlePriority(backgroundContinued: Bool) {
        priorityBurstElapsedSeconds = 0
        consecutivePriorityPrepSteps = 0
        priorityCreditSeconds = backgroundContinued ? 8.0 : 12.0
    }

    mutating func noteHotLiveArrival(backgroundContinued: Bool) {
        let floor: Double = backgroundContinued ? 4.0 : 6.0
        if priorityCreditSeconds < floor {
            priorityCreditSeconds = floor
        }
    }

    mutating func recordPriorityPrepStep(elapsed: Double) {
        let clamped = max(0.05, elapsed)
        consecutivePriorityPrepSteps += 1
        priorityCreditSeconds -= clamped
        priorityBurstElapsedSeconds += clamped
    }

    mutating func recordPriorityWindowStep(elapsed: Double) {
        let clamped = max(0.1, elapsed)
        consecutivePriorityPrepSteps = 0
        priorityCreditSeconds -= clamped
        priorityBurstElapsedSeconds += clamped
    }

    mutating func refillAfterBackfillStep(elapsed: Double, backgroundContinued: Bool) {
        let cap: Double = backgroundContinued ? 8.0 : 16.0
        let refill = max(3.0, min(10.0, max(0.1, elapsed)) * 4.0)
        priorityCreditSeconds = min(cap, max(0, priorityCreditSeconds) + refill)
        priorityBurstElapsedSeconds = 0
        consecutivePriorityPrepSteps = 0
    }

    var canRunPriorityStepFromCredit: Bool {
        consecutivePriorityPrepSteps < Self.maxConsecutivePriorityPrepSteps && priorityCreditSeconds > 0
    }

    func canExtendHotTailBurst(backgroundContinued: Bool, summary: (hasHotLiveWork: Bool, hotPendingSeconds: Double)) -> Bool {
        guard !canRunPriorityStepFromCredit,
              consecutivePriorityPrepSteps < Self.maxConsecutivePriorityPrepSteps,
              !backgroundContinued,
              priorityBurstElapsedSeconds < Self.burstTailMaxElapsedSeconds else {
            return false
        }
        return summary.hasHotLiveWork && summary.hotPendingSeconds <= Self.burstTailMaxPendingSeconds
    }
}
