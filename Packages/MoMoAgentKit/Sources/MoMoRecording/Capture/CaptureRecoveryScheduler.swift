import Foundation

/// Coalesces recovery requests without dropping the request that arrives during the cooldown.
/// The owner must recheck recording intent, generation and audio availability inside the operation.
@MainActor
public final class CaptureRecoveryScheduler {
    private let minimumInterval: TimeInterval
    private var nextAttempt: TimeInterval = 0
    private var pending: Task<Void, Never>?
    private var requestID: UUID?

    public init(minimumInterval: TimeInterval = 30) {
        precondition(minimumInterval.isFinite && minimumInterval >= 0)
        self.minimumInterval = minimumInterval
    }

    deinit { pending?.cancel() }

    public func cancel(resetBudget: Bool = false) {
        pending?.cancel()
        pending = nil
        requestID = nil
        if resetBudget { nextAttempt = 0 }
    }

    public func request(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        guard pending == nil else { return }
        let delay = max(0, nextAttempt - ProcessInfo.processInfo.systemUptime)
        if delay == 0 {
            nextAttempt = ProcessInfo.processInfo.systemUptime + minimumInterval
            await operation()
            return
        }
        let id = UUID()
        requestID = id
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return } // Task.sleep throws only when this request is cancelled.
            guard !Task.isCancelled, let self, self.requestID == id else { return }
            self.pending = nil
            self.requestID = nil
            self.nextAttempt = ProcessInfo.processInfo.systemUptime + self.minimumInterval
            await operation()
        }
    }
}
