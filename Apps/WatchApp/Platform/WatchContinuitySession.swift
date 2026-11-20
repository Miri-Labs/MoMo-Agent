import Foundation
import HealthKit
import os

@MainActor
protocol WatchContinuityManaging: AnyObject {
    var isActive: Bool { get }
    var currentHeartRateBPM: Double? { get }
    var onUpdate: (@MainActor () -> Void)? { get set }
    func ensureActive() async
    func stop() async
}

/// Maintains a watchOS HealthKit workout session (`.mindAndBody`) alongside continuous recording
/// so watchOS keeps the app process alive during phone calls and system audio interruptions,
/// allowing `AVAudioSession.interruptionNotification (.ended)` to automatically resume capture.
/// Always discards the workout on stop so it never pollutes the user's Fitness / Workout history.
@MainActor
final class WatchContinuitySession: NSObject, WatchContinuityManaging {
    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.momoagent.ios.watchkitapp", category: "Continuity")
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var authorizationRequested = false
    private var starting = false
    private var desiredActive = false

    private(set) var isActive = false
    private(set) var currentHeartRateBPM: Double?
    var onUpdate: (@MainActor () -> Void)?

    func ensureActive() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        desiredActive = true
        if isActive || starting { return }
        if let existing = session, existing.state == .running || existing.state == .prepared {
            isActive = true
            onUpdate?()
            return
        }
        starting = true
        defer { starting = false }

        if !authorizationRequested {
            authorizationRequested = true
            let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
            let readTypes: Set<HKObjectType> = [HKQuantityType(.heartRate)]
            do {
                try await healthStore.requestAuthorization(toShare: shareTypes, read: readTypes)
            } catch {
                logger.warning("HealthKit authorization failed (continuing audio-only): \(error.localizedDescription, privacy: .public)")
                return
            }
            guard desiredActive else { return }
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .mindAndBody
        configuration.locationType = .unknown

        do {
            let workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let workoutBuilder = workoutSession.associatedWorkoutBuilder()
            let dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            workoutBuilder.dataSource = dataSource
            workoutSession.delegate = self
            workoutBuilder.delegate = self

            self.session = workoutSession
            self.builder = workoutBuilder

            let startDate = Date()
            workoutSession.startActivity(with: startDate)
            try await workoutBuilder.beginCollection(at: startDate)
            if self.session === workoutSession {
                isActive = true
                onUpdate?()
                logger.info("Watch continuity workout session started")
            }
        } catch {
            logger.warning("Continuity workout session unavailable (continuing audio-only): \(error.localizedDescription, privacy: .public)")
            let failedSession = self.session
            let failedBuilder = self.builder
            self.session = nil
            self.builder = nil
            isActive = false
            currentHeartRateBPM = nil
            failedSession?.end()
            failedBuilder?.discardWorkout()
            onUpdate?()
        }
    }

    func stop() async {
        desiredActive = false
        let activeSession = session
        let activeBuilder = builder
        session = nil
        builder = nil
        let hadState = isActive || currentHeartRateBPM != nil
        isActive = false
        currentHeartRateBPM = nil
        if hadState { onUpdate?() }

        guard activeSession != nil || activeBuilder != nil else { return }
        if let activeSession, activeSession.state != .ended, activeSession.state != .stopped {
            activeSession.end()
        }
        if let activeBuilder {
            try? await activeBuilder.endCollection(at: Date())
            activeBuilder.discardWorkout()
        }
        logger.info("Watch continuity workout session stopped and discarded")
    }

    private func handleStateChange(_ workoutSession: HKWorkoutSession, to state: HKWorkoutSessionState) {
        guard self.session === workoutSession else { return }
        switch state {
        case .running:
            if !isActive {
                isActive = true
                onUpdate?()
            }
        case .ended, .stopped:
            let endingBuilder = self.builder
            self.session = nil
            self.builder = nil
            isActive = false
            currentHeartRateBPM = nil
            endingBuilder?.discardWorkout()
            onUpdate?()
            logger.info("Watch continuity workout session ended externally")
        default:
            break
        }
    }

    private func handleFailure(_ workoutSession: HKWorkoutSession, error: Error) {
        logger.warning("Watch continuity workout session failed: \(error.localizedDescription, privacy: .public)")
        guard self.session === workoutSession else { return }
        let failedBuilder = self.builder
        self.session = nil
        self.builder = nil
        isActive = false
        currentHeartRateBPM = nil
        failedBuilder?.discardWorkout()
        onUpdate?()
    }

    private func handleHeartRateUpdate(_ workoutBuilder: HKLiveWorkoutBuilder, bpm: Double) {
        guard self.builder === workoutBuilder, bpm.isFinite, bpm > 0 else { return }
        currentHeartRateBPM = bpm
        onUpdate?()
    }
}

extension WatchContinuitySession: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor [weak self] in
            self?.handleStateChange(workoutSession, to: toState)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleFailure(workoutSession, error: error)
        }
    }
}

extension WatchContinuitySession: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let quantity = workoutBuilder.statistics(for: heartRateType)?.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor [weak self] in
            self?.handleHeartRateUpdate(workoutBuilder, bpm: bpm)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
