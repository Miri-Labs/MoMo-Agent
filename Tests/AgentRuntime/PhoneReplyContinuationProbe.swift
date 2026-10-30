import UIKit

/// Runs the production lifecycle with injected OS grants; not a real lock-screen delivery test.
@main struct PhoneReplyContinuationProbe {
    @MainActor static func main() async throws {
        var pending = false, stops = 0
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ends: [Int] = []
        let value = PhoneReplyContinuation(begin: { callback in
            expirations.append(callback)
            return UIBackgroundTaskIdentifier(rawValue: expirations.count)
        }, end: { ends.append($0.rawValue) }, pending: { pending }, suspend: { stops += 1 })
        value.leavingForeground()
        precondition(stops == 0 && expirations.isEmpty, "Transient inactivity must not close a subscription")
        value.foreground(); pending = true
        value.leavingForeground(); value.leavingForeground(); value.background()
        precondition(stops == 0 && expirations.count == 1 && value.isActive)
        value.foreground(); value.leavingForeground(); value.background()
        expirations[0]()
        precondition(stops == 0 && value.isActive, "An expired old grant cannot stop a resumed session")
        pending = false
        try await Task.sleep(for: .milliseconds(250))
        precondition(stops == 1 && ends == [1, 2] && !value.isActive, "Release OS time as soon as the reply is cached")
        value.foreground(); pending = true; value.leavingForeground(); value.background()
        expirations[2]()
        precondition(stops == 2 && ends == [1, 2, 3] && !value.isActive)
        expirations[2]()
        precondition(stops == 2 && ends.count == 3, "Expiration must be idempotent")
        value.foreground()
        let denied = PhoneReplyContinuation(begin: { _ in .invalid }, end: { _ in preconditionFailure() },
            pending: { true }, suspend: { stops += 1 })
        denied.leavingForeground(); precondition(stops == 2)
        denied.background(); precondition(stops == 3)
        var budgetEnds = 0
        let bounded = PhoneReplyContinuation(begin: { _ in UIBackgroundTaskIdentifier(rawValue: 9) },
            end: { _ in budgetEnds += 1 }, pending: { true }, suspend: { stops += 1 }, budget: .zero)
        bounded.leavingForeground(); bounded.background()
        try await Task.sleep(for: .milliseconds(20))
        precondition(budgetEnds == 1 && stops == 4 && !bounded.isActive)
        print("PASS: inactive, bounded background receipt, completion, expiry, resume fencing, denied grant")
    }
}
