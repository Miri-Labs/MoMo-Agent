import Foundation
import XCTest
import MoMoArchive
import MoMoSpeech
@testable import PhonePipelineReplay

@MainActor
final class ReceivedAudioTranscriptionTests: XCTestCase {
    func testReceiptBurstSharesOneGrantAndCompletesWithoutForeground() async throws {
        let started = expectation(description: "Background execution admitted")
        started.expectedFulfillmentCount = 2
        let ended = expectation(description: "OS time released")
        let probe = ReceivedExecutionProbe(started: started)
        var starts = 0, ends = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            starts += 1
            return { ends += 1; ended.fulfill() }
        }, start: { finish in
            let handle = await probe.start(finish)
            await probe.complete()
            return handle
        }, stop: { await probe.stop($0, $1) })
        for _ in 0..<20 { receiver.request() }
        await fulfillment(of: [started], timeout: 5)
        await fulfillment(of: [ended], timeout: 5)
        receiver.expire()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1)
        let stops = await probe.stops
        XCTAssertEqual(stops, 0)
    }

    func testArrivalDuringCompletionDrainsAgainWithoutRenewingOSTime() async throws {
        let first = expectation(description: "First drain started")
        let second = expectation(description: "Late receipt starts another drain")
        let ended = expectation(description: "Same OS grant released after the second drain")
        let probe = ReceivedExecutionProbe(started: first)
        var begins = 0, releases = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            begins += 1
            return { releases += 1; ended.fulfill() }
        }, start: { finish in
            let handle = await probe.start(finish)
            if await probe.starts == 2 { second.fulfill() }
            return handle
        }, stop: { await probe.stop($0, $1) })
        await probe.limitStartNotifications(to: 1)
        receiver.request()
        await fulfillment(of: [first], timeout: 5)
        // The coordinator has checked an empty queue, but its completion has not reached this owner.
        receiver.request()
        await probe.complete()
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(releases, 0)
        await probe.complete()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(releases, 1)
        let starts = await probe.starts
        XCTAssertEqual(starts, 2)
    }

    func testFailedDrainDoesNotLoopOnCoalescedReceipts() async throws {
        let started = expectation(description: "Drain started")
        let ended = expectation(description: "Failed drain releases OS time")
        let probe = ReceivedExecutionProbe(started: started)
        let receiver = ReceivedAudioTranscription(begin: { _ in { ended.fulfill() } },
            start: { await probe.start($0) }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        receiver.request()
        await probe.complete(reason: .interrupted, failure: "background_start_failed")
        await fulfillment(of: [ended], timeout: 5)
        let starts = await probe.starts
        XCTAssertEqual(starts, 1)
    }

    func testRecheckStillExpiresWithTheOriginalOSGrant() async throws {
        let first = expectation(description: "First drain started")
        let second = expectation(description: "Recheck started")
        let stopped = expectation(description: "Recheck stopped on original expiration")
        let probe = ReceivedExecutionProbe(started: first, stopped: stopped)
        await probe.limitStartNotifications(to: 1)
        var expiration: (@MainActor @Sendable () -> Void)?
        var begins = 0, releases = 0
        let receiver = ReceivedAudioTranscription(begin: { callback in
            begins += 1; expiration = callback
            return { releases += 1 }
        }, start: { finish in
            let handle = await probe.start(finish)
            if await probe.starts == 2 { second.fulfill() }
            return handle
        }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [first], timeout: 5)
        receiver.request()
        await probe.complete()
        await fulfillment(of: [second], timeout: 5)
        receiver.request()
        try XCTUnwrap(expiration)()
        XCTAssertEqual(releases, 1)
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(begins, 1)
        let reason = await probe.reason
        XCTAssertEqual(reason, .backgroundExpired)
        let starts = await probe.starts
        XCTAssertEqual(starts, 2)
    }

    func testReceiptAfterExpirationWaitsForLateAdmissionThenGetsItsOwnGrant() async throws {
        let started = expectation(description: "Admission pending")
        let stopped = expectation(description: "Late handle cancelled")
        let restarted = expectation(description: "New receipt admitted after the old stop barrier")
        let ended = expectation(description: "New delivery drained")
        let probe = ReceivedExecutionProbe(started: started, stopped: stopped, holdAdmission: true)
        await probe.limitStartNotifications(to: 1)
        var expirations: [@MainActor @Sendable () -> Void] = []
        var starts = 0, ends = 0
        let receiver = ReceivedAudioTranscription(begin: { callback in
            starts += 1; expirations.append(callback)
            return { ends += 1; if ends == 2 { ended.fulfill() } }
        }, start: { finish in
            let handle = await probe.start(finish)
            if await probe.starts == 2 { restarted.fulfill() }
            return handle
        }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        try XCTUnwrap(expirations.first)()
        XCTAssertEqual(ends, 1)
        for _ in 0..<20 { receiver.request() }
        XCTAssertEqual(starts, 1)
        await probe.releaseAdmission()
        await fulfillment(of: [stopped, restarted], timeout: 5)
        let reason = await probe.reason
        XCTAssertEqual(reason, .backgroundExpired)
        XCTAssertEqual(starts, 2)
        expirations[0]()
        XCTAssertEqual(ends, 1)
        await probe.complete()
        await fulfillment(of: [ended], timeout: 5)
        let stops = await probe.stops
        XCTAssertEqual(stops, 1)
    }

    func testInterruptionCancelsReceiptQueuedAfterExpiration() async throws {
        let started = expectation(description: "Admission pending")
        let stopped = expectation(description: "Old execution stopped")
        let unexpectedGrant = expectation(description: "No renewal after foreground or resource interruption")
        unexpectedGrant.isInverted = true
        let probe = ReceivedExecutionProbe(started: started, stopped: stopped, holdAdmission: true)
        var begins = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            begins += 1
            if begins > 1 { unexpectedGrant.fulfill() }
            return {}
        },
            start: { await probe.start($0) }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        receiver.expire()
        receiver.request()
        receiver.expire(reason: .interrupted)
        await probe.releaseAdmission()
        await fulfillment(of: [stopped], timeout: 5)
        await fulfillment(of: [unexpectedGrant], timeout: 0.1)
        XCTAssertEqual(begins, 1)
    }

    func testReceiptDuringPersistentStopWaitsBeforeStartingAgain() async throws {
        let started = expectation(description: "Old execution admitted")
        let stopping = expectation(description: "Persistent stop pending")
        let restarted = expectation(description: "Fresh delivery admitted")
        let ended = expectation(description: "Fresh delivery completed")
        let probe = ReceivedExecutionProbe(started: started, stopped: stopping, holdStop: true)
        await probe.limitStartNotifications(to: 1)
        var begins = 0, releases = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            begins += 1
            return { releases += 1; if releases == 2 { ended.fulfill() } }
        }, start: { finish in
            let handle = await probe.start(finish)
            if await probe.starts == 2 { restarted.fulfill() }
            return handle
        }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        receiver.expire()
        await fulfillment(of: [stopping], timeout: 5)
        receiver.request()
        XCTAssertEqual(begins, 1)
        XCTAssertEqual(releases, 1)
        await probe.releaseStop()
        await fulfillment(of: [restarted], timeout: 5)
        XCTAssertEqual(begins, 2)
        await probe.complete()
        await fulfillment(of: [ended], timeout: 5)
    }

    func testReceiptAfterExpirationCannotRestartAcrossFailedStopBarrier() async throws {
        let started = expectation(description: "Admission pending")
        let stopFailed = expectation(description: "Persistent stop failed")
        let probe = ReceivedExecutionProbe(started: started, holdAdmission: true)
        let unexpectedGrant = expectation(description: "No new grant after failed stop")
        unexpectedGrant.isInverted = true
        var begins = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            begins += 1
            if begins > 1 { unexpectedGrant.fulfill() }
            return {}
        }, start: { await probe.start($0) }, stop: { _, _ in
            stopFailed.fulfill()
            throw CocoaError(.fileWriteUnknown)
        })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        receiver.expire()
        receiver.request()
        await probe.releaseAdmission()
        await fulfillment(of: [stopFailed], timeout: 5)
        await fulfillment(of: [unexpectedGrant], timeout: 0.1)
        XCTAssertEqual(begins, 1)
    }

    func testNewDeliveryDoesNotStartIfReplacementOSTimeIsDenied() async throws {
        let started = expectation(description: "Admission pending")
        let denied = expectation(description: "Fresh delivery requests time once")
        let probe = ReceivedExecutionProbe(started: started, holdAdmission: true)
        var begins = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            begins += 1
            if begins == 1 { return {} }
            denied.fulfill()
            return nil
        }, start: { await probe.start($0) }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        receiver.expire()
        receiver.request()
        await probe.releaseAdmission()
        await fulfillment(of: [denied], timeout: 5)
        let executions = await probe.starts
        XCTAssertEqual(executions, 1)
        XCTAssertEqual(begins, 2)
    }

    func testDeniedTimeDoesNotStartProcessing() {
        let receiver = ReceivedAudioTranscription(begin: { _ in nil }, start: { _ in
            XCTFail("No system execution time was granted")
            throw TranscriptionExecutionError.busy
        }, stop: { _, _ in XCTFail("No execution exists") })
        receiver.request()
        receiver.expire()
    }

    func testSystemTaskWaitsForLateAdmissionAndOwnsSubsequentReceipts() async {
        let started = expectation(description: "Receipt admission pending")
        let ended = expectation(description: "Receipt time released before admission returns")
        let stopped = expectation(description: "Receipt stopped before handoff")
        let probe = ReceivedExecutionProbe(started: started, stopped: stopped, holdAdmission: true)
        var starts = 0, ends = 0
        let receiver = ReceivedAudioTranscription(begin: { _ in
            starts += 1
            return { ends += 1; if ends == 1 { ended.fulfill() } }
        }, start: { await probe.start($0) }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        receiver.expire()
        receiver.request()
        let handoff = Task { await receiver.handOffToSystemTask() }
        await fulfillment(of: [ended], timeout: 5)
        await probe.releaseAdmission()
        await handoff.value
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertEqual(ends, 1)
        receiver.request()
        XCTAssertEqual(starts, 1)
        receiver.systemTaskFinished()
        receiver.request()
        XCTAssertEqual(starts, 2)
        receiver.expire()
    }

    func testReleasingTheOwnerEndsTheGrantAndStopsItsExecution() async throws {
        let started = expectation(description: "Execution admitted")
        let ended = expectation(description: "Owner releases OS time")
        let stopped = expectation(description: "Owner stops execution")
        let probe = ReceivedExecutionProbe(started: started, stopped: stopped)
        var receiver: ReceivedAudioTranscription? = ReceivedAudioTranscription(begin: { _ in { ended.fulfill() } },
            start: { await probe.start($0) }, stop: { await probe.stop($0, $1) })
        receiver?.request()
        await fulfillment(of: [started], timeout: 5)
        receiver = nil
        await fulfillment(of: [ended, stopped], timeout: 5)
        let reason = await probe.reason
        XCTAssertEqual(reason, .interrupted)
    }

    func testOldExpirationCannotCancelTheNextDelivery() async throws {
        let started = expectation(description: "Two separate executions")
        started.expectedFulfillmentCount = 2
        let firstEnded = expectation(description: "First finished")
        let secondEnded = expectation(description: "Second finished")
        let probe = ReceivedExecutionProbe(started: started)
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ends = 0
        let receiver = ReceivedAudioTranscription(begin: { expiration in
            expirations.append(expiration)
            return {
                ends += 1
                if ends == 1 { firstEnded.fulfill() } else { secondEnded.fulfill() }
            }
        }, start: { finish in
            let handle = await probe.start(finish)
            if await probe.starts == 1 { await probe.complete() }
            return handle
        }, stop: { await probe.stop($0, $1) })
        receiver.request()
        await fulfillment(of: [firstEnded], timeout: 5)
        receiver.request()
        await fulfillment(of: [started], timeout: 5)
        expirations[0]()
        XCTAssertEqual(ends, 1)
        await probe.complete()
        await fulfillment(of: [secondEnded], timeout: 5)
        let stops = await probe.stops
        XCTAssertEqual(stops, 0)
    }

    func testReceivedSpeechIsTranscribedWhileSceneRemainsSuspended() async throws {
        let model = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let fixture = model.deletingLastPathComponent().appendingPathComponent("TestFixtures/zh.wav")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoReceivedSpeech-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: fixture, directory: root.appendingPathComponent("capture"))
        let audio = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive,
            wallClockAnchor: Date().addingTimeInterval(-120), closeEpoch: false)
        let speech = try SpeechEngine(bundle: SpeechModelBundle.load(from: model),
            configuration: SpeechConfiguration(), recognitionBackend: .sherpaCoreML)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: speech)
        await coordinator.requestWork()
        let before = await coordinator.snapshot()
        XCTAssertEqual(before.phase, .systemSuspended)
        XCTAssertEqual(before.completedWindows, 0)
        let ended = expectation(description: "Received speech drained")
        let receiver = ReceivedAudioTranscription(begin: { _ in { ended.fulfill() } },
            start: { try await coordinator.startBackgroundAutomatic(onFinished: $0) },
            stop: { try await coordinator.stop(execution: $0, reason: $1) })
        receiver.request()
        // Core ML's first specialization can take longer than a warm recognition run.
        let result = await XCTWaiter.fulfillment(of: [ended], timeout: 180)
        let after = await coordinator.snapshot()
        XCTAssertEqual(result, .completed, "Receipt execution did not drain: \(after)")
        guard result == .completed else { receiver.expire(); return }
        let transcript = try await archive.readTranscript(sessionID: audio.sessionID)
        XCTAssertTrue(transcript.spans.map(\.text).joined().contains("开放时间"))
        XCTAssertGreaterThan(after.completedWindows, 0)
        XCTAssertNil(after.execution)
        XCTAssertEqual(after.phase, .systemSuspended)
    }
}

private actor ReceivedExecutionProbe {
    let started: XCTestExpectation
    let stopped: XCTestExpectation?
    var holdAdmission: Bool
    var holdStop: Bool
    let handle = TranscriptionExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
    var finish: (@Sendable (TranscriptionExecutionCompletion) -> Void)?
    var admission: CheckedContinuation<Void, Never>?
    var stopBarrier: CheckedContinuation<Void, Never>?
    private(set) var starts = 0, stops = 0
    private var startNotificationLimit = Int.max
    private(set) var reason: TranscriptionBatchEndReason?

    init(started: XCTestExpectation, stopped: XCTestExpectation? = nil, holdAdmission: Bool = false, holdStop: Bool = false) {
        self.started = started; self.stopped = stopped; self.holdAdmission = holdAdmission
        self.holdStop = holdStop
    }
    func start(_ finish: @escaping @Sendable (TranscriptionExecutionCompletion) -> Void) async -> TranscriptionExecutionHandle {
        self.finish = finish
        starts += 1
        if holdAdmission { await withCheckedContinuation { admission = $0; started.fulfill() } }
        else if starts <= startNotificationLimit { started.fulfill() }
        return handle
    }
    func releaseAdmission() { holdAdmission = false; admission?.resume(); admission = nil }
    func limitStartNotifications(to count: Int) { startNotificationLimit = count }
    func complete(reason: TranscriptionBatchEndReason = .completed, failure: String? = nil) {
        finish?(.init(execution: handle, reason: reason, failureCode: failure))
    }
    func stop(_ handle: TranscriptionExecutionHandle, _ reason: TranscriptionBatchEndReason) async {
        stops += 1; self.reason = reason
        if holdStop { await withCheckedContinuation { stopBarrier = $0; stopped?.fulfill() } }
        else { stopped?.fulfill() }
    }
    func releaseStop() { holdStop = false; stopBarrier?.resume(); stopBarrier = nil }
}

@MainActor
final class AutomaticSubmissionCoalescingTests: XCTestCase {
    func testRepeatedReceiptsKeepThePendingRequestUntilDelivery() async {
        let calls = SubmissionCalls()
        let submission = AutomaticBackgroundSubmission(eligible: { true }, submit: { await calls.submit() },
            cancel: {}, failure: { XCTFail("Unexpected submission failure") })
        for _ in 0..<20 { await submission.request() }
        let first = await calls.count
        XCTAssertEqual(first, 1)
        submission.delivered()
        await submission.request()
        let second = await calls.count
        XCTAssertEqual(second, 2)
        submission.cancelByUser()
        await submission.request()
        let resumed = await calls.count
        XCTAssertEqual(resumed, 3)
    }

    func testDeliveryBeforeSubmitReturnsStillRearmsExactlyOnce() async {
        let entered = expectation(description: "Submit pending")
        let calls = SubmissionCalls(entered: entered)
        let submission = AutomaticBackgroundSubmission(eligible: { true }, submit: { await calls.submit() },
            cancel: {}, failure: { XCTFail("Unexpected submission failure") })
        let first = Task { await submission.request() }
        await fulfillment(of: [entered], timeout: 5)
        submission.delivered()
        await submission.request()
        await calls.release()
        await first.value
        await submission.request()
        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testCancellationWhileSubmittingDoesNotCancelTheResumedRequest() async {
        let entered = expectation(description: "Submit pending")
        let calls = SubmissionCalls(entered: entered)
        var cancelled = 0
        let submission = AutomaticBackgroundSubmission(eligible: { true }, submit: { await calls.submit() },
            cancel: { cancelled += 1 }, failure: { XCTFail("Unexpected submission failure") })
        let first = Task { await submission.request() }
        await fulfillment(of: [entered], timeout: 5)
        submission.cancelByUser()
        await submission.request()
        await calls.release()
        await first.value
        let count = await calls.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(cancelled, 2)
    }
}

private actor SubmissionCalls {
    let entered: XCTestExpectation?
    private(set) var count = 0
    private var gate: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation? = nil) { self.entered = entered }
    func submit() async {
        count += 1
        if count == 1, let entered {
            await withCheckedContinuation { gate = $0; entered.fulfill() }
        }
    }
    func release() { gate?.resume(); gate = nil }
}
