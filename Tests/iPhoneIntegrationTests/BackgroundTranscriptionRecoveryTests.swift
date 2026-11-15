import Foundation
import XCTest
import MoMoArchive
import MoMoContracts
#if os(iOS)
@testable import MoMoAgent
private typealias RecoveryExecutionHandle = MoMoAgent.TranscriptionExecutionHandle
private typealias RecoveryExecutionCompletion = MoMoAgent.TranscriptionExecutionCompletion
#else
@testable import PhonePipelineReplay
private typealias RecoveryExecutionHandle = TranscriptionExecutionHandle
private typealias RecoveryExecutionCompletion = TranscriptionExecutionCompletion
#endif

@MainActor
final class BackgroundTranscriptionRecoveryTests: XCTestCase {
    func testEightHourBatchReportsDurableProgressAcrossTheWholeBacklog() throws {
        let scale = ContinuedTranscriptionProgress.totalUnits
        let twoMinutes = try batch(prepared: 120, completed: 120)
        var progress = ContinuedTranscriptionProgress.completedUnits(batch: twoMinutes, previous: 0)
        XCTAssertGreaterThan(progress, 0)
        XCTAssertLessThan(progress, scale / 100, "Two minutes must not appear to finish an eight-hour task")
        for _ in 0..<600 {
            let unchanged = ContinuedTranscriptionProgress.completedUnits(batch: twoMinutes, previous: progress)
            XCTAssertEqual(unchanged, progress, "Elapsed time alone cannot advance progress")
        }
        let halfway = try batch(prepared: 14_400, completed: 14_400)
        progress = ContinuedTranscriptionProgress.completedUnits(batch: halfway, previous: progress)
        XCTAssertEqual(progress, scale / 2)
        let advanced = ContinuedTranscriptionProgress.completedUnits(
            batch: try batch(prepared: 14_420, completed: 14_420), previous: progress)
        XCTAssertGreaterThan(advanced, progress, "Later windows must still advance after hours of work")
        XCTAssertEqual(ContinuedTranscriptionProgress.completedUnits(batch: twoMinutes, previous: advanced), advanced)
        let allCoverage = try batch(prepared: 28_800, completed: 28_800)
        XCTAssertEqual(ContinuedTranscriptionProgress.completedUnits(batch: allCoverage, previous: advanced), scale - 1)
        let finished = try batch(prepared: 28_800, completed: 28_800, state: .completed)
        XCTAssertEqual(ContinuedTranscriptionProgress.completedUnits(batch: finished, previous: advanced), scale)
    }

    func testSystemGrantDrainsMultipleBatchesWithoutAnotherForegroundVisit() async {
        let completed = expectation(description: "All three batches drained")
        let chain = BackgroundBatchChain()
        let grant = TranscriptionTaskGrant(start: { await chain.start($0) },
            followUp: { await chain.next($0) }, drainFollowUps: true,
            stop: { _, _ in XCTFail("An admitted task must keep its grant until complete or expired") }) { success, failure in
                XCTAssertTrue(success)
                XCTAssertNil(failure)
                completed.fulfill()
            }
        await grant.run()
        await fulfillment(of: [completed], timeout: 5)
        let count = await chain.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(grant.endReason, .completed)
    }

    func testLateAdmissionCannotReplaceTheNextStagesExecution() async throws {
        let firstAdmitted = expectation(description: "First admission held after completion")
        let secondAdmitted = expectation(description: "Second stage running")
        let finished = expectation(description: "Second stage expired")
        let probe = LateBackgroundAdmission(first: firstAdmitted, second: secondAdmitted)
        let grant = TranscriptionTaskGrant(start: { await probe.start($0) },
            followUp: { await probe.next($0) }, drainFollowUps: true,
            stop: { handle, _ in await probe.stop(handle) }) { success, failure in
                XCTAssertFalse(success)
                XCTAssertNil(failure)
                finished.fulfill()
            }
        let run = Task { await grant.run() }
        await fulfillment(of: [firstAdmitted, secondAdmitted], timeout: 5)
        await probe.release()
        await run.value
        grant.expire(reason: .backgroundExpired)
        await fulfillment(of: [finished], timeout: 5)
        let stopped = await probe.stopped
        let second = await probe.secondHandle
        XCTAssertEqual(stopped, second)
    }

    func testFailedSchedulerSubmissionRetriesWithoutNewAudioOrForeground() async {
        let firstDelay = expectation(description: "First retry scheduled")
        let secondDelay = expectation(description: "Second retry scheduled")
        let submitted = expectation(description: "Third submission accepted")
        let probe = BackgroundSubmissionRetry(delays: [firstDelay, secondDelay], submitted: submitted)
        var failures = 0
        let submission = AutomaticBackgroundSubmission(eligible: { true },
            submit: { try await probe.submit() }, cancel: {}, failure: { failures += 1 },
            sleep: { await probe.sleep($0) })
        await submission.request()
        await fulfillment(of: [firstDelay], timeout: 5)
        for _ in 0..<20 { await submission.request() }
        await probe.release()
        await fulfillment(of: [secondDelay], timeout: 5)
        await probe.release()
        await fulfillment(of: [submitted], timeout: 5)
        let delays = await probe.delays
        let attempts = await probe.attempts
        XCTAssertEqual(delays, [5, 10])
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(failures, 2)
    }

    func testUserCancellationPreventsSleepingSchedulerRetry() async {
        let waiting = expectation(description: "Retry sleeping")
        let unexpected = expectation(description: "Cancelled request must not submit again")
        unexpected.isInverted = true
        let probe = BackgroundSubmissionRetry(delays: [waiting], submitted: unexpected, failures: 1)
        let submission = AutomaticBackgroundSubmission(eligible: { true },
            submit: { try await probe.submit() }, cancel: {}, failure: {},
            sleep: { await probe.sleep($0) })
        await submission.request()
        await fulfillment(of: [waiting], timeout: 5)
        submission.cancelByUser()
        await probe.release()
        await fulfillment(of: [unexpected], timeout: 0.1)
        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)
    }

    private func batch(prepared: Int64, completed: Int64,
                       state: TranscriptionBatchState = .running) throws -> TranscriptionBatch {
        struct Wire: Encodable {
            let id = UUID()
            let configurationFingerprint = String(repeating: "a", count: 64)
            let state: TranscriptionBatchState
            let windowIDs: [String] = []
            let coverage: [TranscriptionBatchCoverage]
        }
        let coverage = TranscriptionBatchCoverage(sessionID: UUID(), epochID: UUID(), timebaseHz: 16_000,
            frozen: [try FrameRange(start: 0, count: 28_800 * 16_000)], noSpeech: [],
            prepared: [try FrameRange(start: 0, count: prepared * 16_000)],
            completed: [try FrameRange(start: 0, count: completed * 16_000)], removed: [])
        return try JSONDecoder().decode(TranscriptionBatch.self,
            from: JSONEncoder().encode(Wire(state: state, coverage: [coverage])))
    }
}

private actor BackgroundBatchChain {
    private(set) var count = 0
    func start(_ finish: @escaping @Sendable (RecoveryExecutionCompletion) -> Void) -> RecoveryExecutionHandle {
        count += 1
        let handle = RecoveryExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        finish(.init(execution: handle, reason: .completed, failureCode: nil))
        return handle
    }
    func next(_ finish: @escaping @Sendable (RecoveryExecutionCompletion) -> Void) -> RecoveryExecutionHandle? {
        count < 3 ? start(finish) : nil
    }
}

private actor LateBackgroundAdmission {
    let first: XCTestExpectation, second: XCTestExpectation
    let secondHandle = RecoveryExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var stopped: RecoveryExecutionHandle?
    init(first: XCTestExpectation, second: XCTestExpectation) { self.first = first; self.second = second }
    func start(_ finish: @escaping @Sendable (RecoveryExecutionCompletion) -> Void) async -> RecoveryExecutionHandle {
        let handle = RecoveryExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        finish(.init(execution: handle, reason: .completed, failureCode: nil))
        await withCheckedContinuation { gate = $0; first.fulfill() }
        return handle
    }
    func next(_ finish: @escaping @Sendable (RecoveryExecutionCompletion) -> Void) -> RecoveryExecutionHandle? {
        second.fulfill()
        return secondHandle
    }
    func release() { gate?.resume(); gate = nil }
    func stop(_ handle: RecoveryExecutionHandle) { stopped = handle }
}

private actor BackgroundSubmissionRetry {
    private let notifications: [XCTestExpectation]
    private let submitted: XCTestExpectation
    private let failures: Int
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var delays: [TimeInterval] = []
    private(set) var attempts = 0
    init(delays: [XCTestExpectation], submitted: XCTestExpectation, failures: Int = 2) {
        notifications = delays; self.submitted = submitted; self.failures = failures
    }
    func submit() throws {
        attempts += 1
        if attempts <= failures { throw CocoaError(.fileReadUnknown) }
        submitted.fulfill()
    }
    func sleep(_ delay: TimeInterval) async {
        delays.append(delay)
        await withCheckedContinuation { gate = $0; notifications[delays.count - 1].fulfill() }
    }
    func release() { gate?.resume(); gate = nil }
}
