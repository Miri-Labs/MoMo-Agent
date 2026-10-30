import UIKit

/// Finishes an already pending reply under a finite UIKit grant. The Mac owns execution.
@MainActor final class PhoneReplyContinuation {
    typealias Begin = @MainActor (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    private let begin: Begin
    private let end: @MainActor (UIBackgroundTaskIdentifier) -> Void
    private let pending: @MainActor () -> Bool
    private let suspend: @MainActor () -> Void
    private let budget: Duration
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var inactive = false
    private var backgrounded = false
    var isActive: Bool { identifier != .invalid }

    convenience init(pending: @escaping @MainActor () -> Bool, suspend: @escaping @MainActor () -> Void) {
        self.init(begin: { UIApplication.shared.beginBackgroundTask(withName: "Receive assistant reply", expirationHandler: $0) },
                  end: { UIApplication.shared.endBackgroundTask($0) }, pending: pending, suspend: suspend)
    }

    init(begin: @escaping Begin, end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void,
         pending: @escaping @MainActor () -> Bool, suspend: @escaping @MainActor () -> Void,
         budget: Duration = .seconds(25)) {
        self.begin = begin; self.end = end; self.pending = pending; self.suspend = suspend; self.budget = budget
    }

    func leavingForeground() {
        guard !inactive else { return }
        inactive = true
        guard pending() else { return }
        let owner = UUID(); generation = owner
        identifier = begin { [weak self] in
            guard let self, self.generation == owner else { return }
            self.finish()
        }
        guard isActive else { return }
        let deadline = ContinuousClock.now.advanced(by: budget)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == owner else { return }
                if !self.pending() || ContinuousClock.now >= deadline { self.finish(); return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    func background() {
        backgrounded = true
        if !isActive { suspend() }
    }

    func foreground() {
        inactive = false; backgrounded = false
        finish()
    }

    private func finish() {
        generation = UUID()
        monitor?.cancel(); monitor = nil
        let old = identifier; identifier = .invalid
        if old != .invalid { end(old) }
        if backgrounded { suspend() }
    }
}
