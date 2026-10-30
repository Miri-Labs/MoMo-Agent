import Foundation

/// Serializes the fixed task identifier so a late submit cannot undo a user's cancellation.
@MainActor
final class AutomaticBackgroundSubmission {
    private let eligible: @MainActor () async throws -> Bool
    private let submit: @Sendable () async throws -> Void
    private let cancel: @MainActor () -> Void
    private let failure: @MainActor () -> Void
    private var running = false
    private var requested = false
    private var generation: UInt64 = 0
    private var pending = false
    private var deliveryRevision: UInt64 = 0

    init(eligible: @escaping @MainActor () async throws -> Bool,
         submit: @escaping @Sendable () async throws -> Void,
         cancel: @escaping @MainActor () -> Void, failure: @escaping @MainActor () -> Void) {
        self.eligible = eligible
        self.submit = submit
        self.cancel = cancel
        self.failure = failure
    }

    func request() async {
        guard !pending else { return }
        requested = true
        guard !running else { return }
        running = true
        defer { running = false }
        while requested {
            requested = false
            let submittedGeneration = generation, submittedDelivery = deliveryRevision
            do {
                guard !pending, try await eligible(), submittedGeneration == generation else { continue }
                try await submit()
                if submittedGeneration != generation { cancel() }
                else if submittedDelivery == deliveryRevision { pending = true }
            } catch {
                if submittedGeneration == generation { failure() }
            }
        }
    }

    func cancelByUser() {
        generation &+= 1
        requested = false
        pending = false
        cancel()
    }

    func delivered() {
        deliveryRevision &+= 1
        pending = false
    }
}
