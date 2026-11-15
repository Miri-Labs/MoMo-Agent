import Foundation
import OSLog

/// Serializes the fixed task identifier so a late submit cannot undo a user's cancellation.
@MainActor
final class AutomaticBackgroundSubmission {
    private let eligible: @MainActor () async throws -> Bool
    private let submit: @Sendable () async throws -> Void
    private let cancel: @MainActor () -> Void
    private let failure: @MainActor () -> Void
    private let uptime: @MainActor () -> Double
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var retryTask: Task<Void, Never>?
    private var retryDelay: TimeInterval = 5
    private var running = false
    private var requested = false
    private var generation: UInt64 = 0
    private var pending = false
    private var pendingVerifiedUptime: Double = -.infinity
    private var deliveryRevision: UInt64 = 0

    init(eligible: @escaping @MainActor () async throws -> Bool,
         submit: @escaping @Sendable () async throws -> Void,
         cancel: @escaping @MainActor () -> Void, failure: @escaping @MainActor () -> Void,
         uptime: @escaping @MainActor () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) * 1e-9 },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.eligible = eligible
        self.submit = submit
        self.cancel = cancel
        self.failure = failure
        self.uptime = uptime
        self.sleep = sleep
    }

    deinit { retryTask?.cancel() }

    func request() async {
        guard retryTask == nil else { return }
        if pending, uptime() - pendingVerifiedUptime < 60 { return }
        requested = true
        guard !running else { return }
        running = true
        defer { running = false }
        while requested {
            requested = false
            if pending, uptime() - pendingVerifiedUptime < 60 { continue }
            let submittedGeneration = generation, submittedDelivery = deliveryRevision
            do {
                guard try await eligible(), submittedGeneration == generation else { continue }
                try await submit()
                retryDelay = 5
                if submittedGeneration != generation { cancel() }
                else if submittedDelivery == deliveryRevision {
                    pending = true
                    pendingVerifiedUptime = uptime()
                }
            } catch {
                if submittedGeneration == generation {
                    let native = error as NSError
                    Logger(subsystem: "MoMoAgent", category: "BackgroundTranscription")
                        .error("Background submission failed: \(native.domain, privacy: .public) / \(native.code)")
                    failure()
                    requested = false
                    scheduleRetry(generation: submittedGeneration)
                }
            }
        }
    }

    func cancelByUser() {
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 5
        requested = false
        pending = false
        pendingVerifiedUptime = -.infinity
        cancel()
    }

    func delivered() {
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 5
        deliveryRevision &+= 1
        pending = false
        pendingVerifiedUptime = -.infinity
    }

    private func scheduleRetry(generation: UInt64) {
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(300, delay * 2)
        // This timer only runs with OS execution time; it cannot wake a suspended app.
        retryTask = Task { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.retryTask = nil
            await self.request()
        }
    }
}
