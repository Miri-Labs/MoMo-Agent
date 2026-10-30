import Foundation
import Testing
@testable import MoMoRecording

@Suite @MainActor struct CaptureRecoverySchedulerTests {
    private static let interval: TimeInterval = 0.05

    @Test func repeatedPromptsEventuallyResumeInsteadOfDroppingTheSecondRequest() async throws {
        let scheduler = CaptureRecoveryScheduler(minimumInterval: Self.interval)
        let attempts = Attempts()
        await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        #expect(attempts.times.count == 1)
        for _ in 0..<10 {
            await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        }
        #expect(attempts.times.count == 1)
        try await waitForCount(2, in: attempts)
        #expect(attempts.times[1] - attempts.times[0] >= Self.interval - 0.002)
        try await Task.sleep(for: .milliseconds(100))
        #expect(attempts.times.count == 2, "Repeated end notifications must coalesce to one attempt.")
    }

    @Test(arguments: [CaptureIntent.paused, .stopped])
    func userActionCancelsAPendingRestart(intent: CaptureIntent) async throws {
        let scheduler = CaptureRecoveryScheduler(minimumInterval: Self.interval)
        let state = State()
        _ = state.capture.start()
        state.capture.interrupt()
        await scheduler.request { state.attempts += 1 }
        await scheduler.request { state.attempts += 1 }
        if intent == .paused { state.capture.pause() } else { state.capture.stop() }
        scheduler.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.attempts == 1)
        #expect(state.capture.intent == intent)
    }

    @Test func aNewInterruptionReplacesPendingResumeWithoutResettingItsBudget() async throws {
        let scheduler = CaptureRecoveryScheduler(minimumInterval: Self.interval)
        let attempts = Attempts()
        await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        await scheduler.request { Issue.record("Cancelled interruption restarted") }
        scheduler.cancel()
        await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        #expect(attempts.times.count == 1)
        try await waitForCount(2, in: attempts)
        #expect(attempts.times[1] - attempts.times[0] >= Self.interval - 0.002)
    }

    @Test func explicitRetryIsImmediateAndCancelsOlderAutomaticRequest() async throws {
        let scheduler = CaptureRecoveryScheduler(minimumInterval: 30)
        let attempts = Attempts()
        await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        await scheduler.request { Issue.record("Old automatic request survived a manual retry") }
        scheduler.cancel(resetBudget: true)
        await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        #expect(attempts.times.count == 2)
    }

    @Test func priorityRefusalCanScheduleItsOwnRetry() async throws {
        let scheduler = CaptureRecoveryScheduler(minimumInterval: Self.interval)
        let attempts = Attempts()
        await scheduler.request {
            attempts.times.append(ProcessInfo.processInfo.systemUptime)
            await scheduler.request { attempts.times.append(ProcessInfo.processInfo.systemUptime) }
        }
        try await waitForCount(2, in: attempts)
        #expect(attempts.times[1] - attempts.times[0] >= Self.interval - 0.002)
    }

    @Test func pendingDelayDoesNotRetainItsOwner() async throws {
        var scheduler: CaptureRecoveryScheduler? = .init(minimumInterval: 30)
        weak var weakScheduler = scheduler
        await scheduler?.request {}
        await scheduler?.request { Issue.record("Released scheduler executed recovery") }
        scheduler = nil
        #expect(weakScheduler == nil)
        await Task.yield()
    }

    private func waitForCount(_ count: Int, in attempts: Attempts) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while attempts.times.count < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(attempts.times.count == count)
    }

    @MainActor private final class Attempts { var times: [TimeInterval] = [] }
    @MainActor private final class State { var capture = CaptureState(); var attempts = 0 }
}
