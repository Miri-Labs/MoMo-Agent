import Foundation
import SwiftUI
import UIKit
import XCTest
import MoMoArchive
import MoMoContracts
import MoMoRecording
import MoMoAgentClient
import Security
@testable import MoMoAgent

/// Controlled platform events test the adapter contract; they are not iOS scheduler acceptance.
@MainActor
final class BackgroundGrantLifecycleTests: XCTestCase {
    func testManualRetryWaitsForItsCoalescedFollowup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoRecoveryWait-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: device)
        let agent = try PhoneRemoteAgent(directory: root.appendingPathComponent("remote"), archive: archive, deviceID: device)
        let endpoint = URL(string: "https://fixture.invalid")!
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: endpoint, dataURL: endpoint)
        defer {
            agent.contextDelivery.expire()
            PairingHoldProtocol.releaseProbe()
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "MoMoAgent.MacConnection",
                           kSecAttrAccount as String: connection.instanceID.uuidString] as CFDictionary)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingHoldProtocol.self]
        PairingHoldProtocol.respond(workspace: connection.workspaceID)
        let applied = await agent.connect(configuration: String(decoding: try JSONEncoder().encode(connection), as: UTF8.self),
                                          credential: "fixture", requestConfiguration: configuration)
        XCTAssertTrue(applied, agent.failure ?? "No pairing error was reported")
        agent.contextDelivery.expire()
        let first = expectation(description: "First recovery probe held")
        PairingHoldProtocol.holdProbe(first)
        let firstRetry = Task { await agent.reconnect() }
        await fulfillment(of: [first], timeout: 5)
        let queued = expectation(description: "Manual retry requested")
        var returned = false
        let manual = Task { queued.fulfill(); await agent.reconnect(); returned = true }
        await fulfillment(of: [queued], timeout: 5)
        let second = expectation(description: "Coalesced probe held")
        PairingHoldProtocol.holdProbe(second)
        PairingHoldProtocol.releaseProbe()
        await fulfillment(of: [second], timeout: 5)
        XCTAssertFalse(returned, "Manual refresh must await its own coalesced attempt")
        PairingHoldProtocol.releaseProbe()
        await firstRetry.value; await manual.value
        XCTAssertTrue(returned)
    }

    func testExplicitConnectionPreemptsAutomaticRecoveryAndReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoConnectionPriority-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: device)
        let agent = try PhoneRemoteAgent(directory: root.appendingPathComponent("remote"), archive: archive, deviceID: device)
        let endpoint = URL(string: "https://fixture.invalid")!
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: endpoint, dataURL: endpoint)
        defer {
            agent.leavingForeground()
            agent.contextDelivery.expire()
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "MoMoAgent.MacConnection",
                           kSecAttrAccount as String: connection.instanceID.uuidString] as CFDictionary)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingHoldProtocol.self]
        PairingHoldProtocol.respond(workspace: connection.workspaceID)
        agent.foreground()
        let applied = await agent.connect(configuration: String(decoding: try JSONEncoder().encode(connection), as: UTF8.self),
                                          credential: "fixture", requestConfiguration: configuration)
        XCTAssertTrue(applied, agent.failure ?? "No pairing error was reported")
        XCTAssertNotNil(agent.store)
        XCTAssertTrue(agent.connecting, "A successful foreground pairing starts automatic recovery")
        XCTAssertFalse(agent.pairingInProgress)
        let replacement = await agent.connect(configuration: "invalid", credential: "replacement")
        XCTAssertFalse(replacement)
        XCTAssertNotNil(agent.failure, "Explicit configuration must be attempted, not silently ignored during recovery")
        XCTAssertEqual(agent.connection, connection)
    }

    func testLeavingForegroundDoesNotReleaseAnInFlightPairing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoPairingLifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: device)
        let agent = try PhoneRemoteAgent(directory: root.appendingPathComponent("remote"), archive: archive, deviceID: device)
        let endpoint = URL(string: "https://fixture.invalid")!
        let connection = AgentConnection(workspaceID: UUID(), assistantID: UUID(), instanceID: UUID(), baseURL: endpoint, dataURL: endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingHoldProtocol.self]
        let entered = expectation(description: "Pairing capabilities in flight")
        PairingHoldProtocol.observe(entered)
        agent.foreground()
        let pairing = Task {
            return await agent.connect(configuration: String(decoding: try JSONEncoder().encode(connection), as: UTF8.self),
                                credential: "fixture", requestConfiguration: configuration)
        }
        await fulfillment(of: [entered], timeout: 5)
        agent.leavingForeground()
        XCTAssertTrue(agent.connecting, "Scene recovery cancellation must not unlock an ongoing pairing")
        let secondApplied = await agent.connect(configuration: "invalid", credential: "fixture")
        XCTAssertFalse(secondApplied, "Busy pairing must explicitly report that it was not applied")
        XCTAssertNil(agent.failure, "A second pairing must not be admitted before the first finishes")
        pairing.cancel()
        let firstApplied = try await pairing.value
        XCTAssertFalse(firstApplied)
        XCTAssertFalse(agent.connecting)
    }

    func testSceneContinuationEndsOnceAndAnOldExpirationCannotStopTheNextGrant() async throws {
        var expirations: [@MainActor @Sendable () -> Void] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var stops = 0
        let continuation = PhoneTranscriptionContinuation(begin: { expiration in
            expirations.append(expiration)
            return UIBackgroundTaskIdentifier(rawValue: expirations.count)
        }, end: { ended.append($0) }, stop: { stops += 1 })
        continuation.start()
        continuation.start()
        XCTAssertEqual(expirations.count, 1)
        continuation.finish()
        continuation.start()
        expirations[0]()
        await Task.yield()
        XCTAssertTrue(continuation.isActive)
        XCTAssertEqual(stops, 0)
        await continuation.expire()
        await continuation.expire()
        continuation.finish()
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(continuation.isActive)
        XCTAssertEqual(ended.map(\.rawValue), [1, 2])
    }

    func testSceneContinuationReleasesOSTimeBeforeTheDurableStopAndCannotRestartDuringExpiration() async throws {
        let stopping = expectation(description: "Stop barrier")
        let gate = PreparationGate(entered: stopping)
        var starts = 0, ends = 0
        let continuation = PhoneTranscriptionContinuation(begin: { _ in
            starts += 1
            return UIBackgroundTaskIdentifier(rawValue: starts)
        }, end: { _ in ends += 1 }, stop: { await gate.wait() })
        continuation.start()
        let expired = Task { await continuation.expire() }
        await fulfillment(of: [stopping], timeout: 5)
        continuation.finish()
        continuation.start()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(ends, 1, "The OS grant must end before waiting for cancellation.")
        XCTAssertFalse(continuation.isActive)
        await gate.open()
        await expired.value
        XCTAssertEqual(ends, 1)
    }

    func testExpirationCallbackReleasesOSTimeBeforeReturning() async throws {
        let stopping = expectation(description: "Stop barrier")
        let gate = PreparationGate(entered: stopping)
        var expiration: (@MainActor @Sendable () -> Void)?
        var ends = 0
        let continuation = PhoneTranscriptionContinuation(begin: { callback in
            expiration = callback
            return UIBackgroundTaskIdentifier(rawValue: 1)
        }, end: { _ in ends += 1 }, stop: { await gate.wait() })
        continuation.start()
        try XCTUnwrap(expiration)()
        XCTAssertEqual(ends, 1, "Returning from UIKit's callback with an active grant can terminate the app.")
        XCTAssertFalse(continuation.isActive)
        await fulfillment(of: [stopping], timeout: 5)
        try XCTUnwrap(expiration)()
        continuation.finish()
        XCTAssertEqual(ends, 1)
        await gate.open()
    }

    func testDeniedSceneContinuationDoesNotPretendToHaveBackgroundTime() {
        var ends = 0
        let continuation = PhoneTranscriptionContinuation(begin: { _ in .invalid },
            end: { _ in ends += 1 }, stop: { XCTFail("There is no grant to expire") })
        continuation.start()
        XCTAssertFalse(continuation.isActive)
        continuation.finish()
        XCTAssertEqual(ends, 0)
    }

    func testProcessLaunchWithoutSceneRestoresInboxAndQueuesReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MoMoColdReceive-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID()
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: device)
        let agent = try PhoneRemoteAgent(directory: root.appendingPathComponent("remote"), archive: archive, deviceID: device)
        let controls = try ControlInbox(directory: root.appendingPathComponent("controls"))
        let receiver = PhoneReceiveCoordinator(archive: archive, controls: controls,
            identity: ReceiverIdentity(messageID: UUID(), receiverDeviceID: device, libraryInstanceID: archive.libraryInstanceID))
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("encoder"),
            sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "cold-launch-test",
            sourceKind: .fixture, targetFrames: 160, wallClockAnchor: Date(), timezoneOffset: 0)
        let segment = try XCTUnwrap(writer.append(Array(repeating: 0, count: 160)).first)
        _ = try writer.finish()
        _ = try archive.inbox.preserve(fileURL: segment.audioURL, envelope: segment.envelope)
        let runtime = try PhoneRuntime(archive: archive, remoteAgent: agent, playback: AudioPlaybackController(archive: archive),
            receiver: receiver, transport: nil, speech: nil, speechFailure: nil)
        var creations = 0
        let bootstrap = PhoneBootstrap { _ in creations += 1; return runtime }
        bootstrap.launch()
        XCTAssertTrue(bootstrap.runtime === runtime, "The WC delegate must be installed during process launch, before any scene task.")
        bootstrap.launch()
        await runtime.start(backgroundOnly: true)
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(runtime.ready)
        XCTAssertNil(runtime.failure)
        let receipts = try await archive.pendingReceipts()
        XCTAssertEqual(receipts.map(\.chunkID), [segment.envelope.manifest.chunkID])
        XCTAssertTrue(try archive.inbox.pendingItems().isEmpty)
        XCTAssertTrue(runtime.library.recordings.isEmpty, "A scene-free launch must not construct the library presentation.")
        await runtime.foreground()
        XCTAssertEqual(runtime.library.recordings.map(\.id), [segment.envelope.manifest.sessionID])
    }

    func testExpirationDuringPreparationEndsImmediatelyAndNeverAdmitsWork() async throws {
        let preparing = expectation(description: "Preparation started")
        let completed = expectation(description: "Expired before preparation ended")
        let gate = PreparationGate(entered: preparing)
        var results: [Bool] = []
        let grant = TranscriptionTaskGrant(prepare: { await gate.wait() }, start: { _ in
            XCTFail("Expired preparation must not admit an execution")
            throw TestFailure.stopFailed
        }, stop: { _, _ in XCTFail("No execution exists to stop") }) { success, _ in
            results.append(success)
            completed.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [preparing], timeout: 5)
        grant.expire(reason: .backgroundExpired)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(results, [false])
        await gate.open()
        await run.value
        XCTAssertEqual(results, [false])
        XCTAssertNil(grant.execution)
    }

    func testExpirationDuringAdmissionWaitsForStopBarrierAndCompletesOnce() async throws {
        let admitted = expectation(description: "Admission started")
        let stopping = expectation(description: "Stop barrier started")
        let completed = expectation(description: "System completion")
        let harness = GrantHarness(admitted: admitted, stopping: stopping)
        var completions: [(Bool, String?)] = []
        let grant = TranscriptionTaskGrant(start: { await harness.start($0) }, stop: { try await harness.stop($0, $1) }) { success, failure in
            completions.append((success, failure))
            completed.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [admitted], timeout: 5)
        grant.expire(reason: .systemEndedUnknown)
        XCTAssertTrue(completions.isEmpty)
        await harness.releaseAdmission()
        await fulfillment(of: [stopping], timeout: 5)
        XCTAssertTrue(completions.isEmpty, "The persistent stop barrier must precede system completion")
        await harness.deliverLateCompletion()
        await harness.releaseStop()
        await run.value
        await fulfillment(of: [completed], timeout: 5)
        grant.expire(reason: .systemEndedUnknown)
        await harness.deliverLateCompletion()
        await Task.yield()
        XCTAssertEqual(completions.count, 1)
        XCTAssertFalse(completions[0].0)
        XCTAssertNil(completions[0].1)
        let reasons = await harness.stopReasons
        XCTAssertEqual(reasons, [.systemEndedUnknown])
    }

    func testCompletionCanArriveBeforeAdmissionReturns() async throws {
        let admitted = expectation(description: "Admission started")
        let completed = expectation(description: "Early completion")
        let harness = GrantHarness(admitted: admitted, stopping: nil)
        var results: [Bool] = []
        let grant = TranscriptionTaskGrant(start: { await harness.start($0) }, stop: { try await harness.stop($0, $1) }) { success, _ in
            results.append(success)
            completed.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [admitted], timeout: 5)
        await harness.deliverLateCompletion()
        await fulfillment(of: [completed], timeout: 5)
        grant.expire(reason: .systemEndedUnknown)
        await harness.releaseAdmission()
        await run.value
        XCTAssertEqual(results, [true])
        let reasons = await harness.stopReasons
        XCTAssertTrue(reasons.isEmpty)
    }

    func testStopPersistenceFailureStillEndsSystemGrantAsFailure() async throws {
        let completed = expectation(description: "Failure completion")
        let handle = MoMoAgent.TranscriptionExecutionHandle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        var results: [(Bool, String?)] = []
        let grant = TranscriptionTaskGrant(start: { _ in handle }, stop: { _, _ in throw TestFailure.stopFailed }) { success, failure in
            results.append((success, failure))
            completed.fulfill()
        }
        await grant.run()
        grant.expire(reason: .backgroundExpired)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].0)
        XCTAssertEqual(results[0].1, "archive_cancel_barrier_failed")
    }

    func testGrantFollowUpStageRunsAfterFirstStageCompletesAndHonorsExpirationBarrier() async throws {
        let stage1Admitted = expectation(description: "Stage 1 admitted")
        let stage2Admitted = expectation(description: "Stage 2 admitted")
        let stage2Stopping = expectation(description: "Stage 2 stop barrier")
        let grantCompleted = expectation(description: "Grant completed")
        let stage1 = GrantHarness(admitted: stage1Admitted, stopping: nil)
        let stage2 = GrantHarness(admitted: stage2Admitted, stopping: stage2Stopping)
        var outcomes: [(Bool, String?)] = []
        let grant = TranscriptionTaskGrant(
            start: { await stage1.start($0) },
            followUp: { await stage2.start($0) },
            stop: { execution, reason in try await stage2.stop(execution, reason) }
        ) { success, failure in
            outcomes.append((success, failure))
            grantCompleted.fulfill()
        }
        let run = Task { await grant.run() }
        await fulfillment(of: [stage1Admitted], timeout: 5)
        await stage1.releaseAdmission()
        await run.value
        await stage1.deliverLateCompletion()
        await fulfillment(of: [stage2Admitted], timeout: 5)
        XCTAssertTrue(outcomes.isEmpty, "Grant must stay open while follow-up stage runs")
        grant.expire(reason: .backgroundExpired)
        await stage2.releaseAdmission()
        await fulfillment(of: [stage2Stopping], timeout: 5)
        XCTAssertTrue(outcomes.isEmpty, "Expiration during follow-up admission must await stop barrier")
        await stage2.releaseStop()
        await fulfillment(of: [grantCompleted], timeout: 5)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].0)
        XCTAssertNil(outcomes[0].1)
        let reasons = await stage2.stopReasons
        XCTAssertEqual(reasons, [.backgroundExpired])
    }

    func testTimelineDurationDisplaysHoursAndMinutesWithoutWholeHourStuckRounding() {
        let sec45 = TimelineDate.duration(45)
        let min2 = TimelineDate.duration(120)
        let near1Hr = TimelineDate.duration(3_580)
        let exact3Hr = TimelineDate.duration(10_800)
        let threeHr21Min = TimelineDate.duration(3 * 3_600 + 21 * 60)
        XCTAssertTrue(sec45.contains("45"))
        XCTAssertTrue(min2.contains("2"))
        XCTAssertFalse(near1Hr.contains("60"), "59m40s must roll over to 1 hour, not 60 minutes: \(near1Hr)")
        XCTAssertTrue(near1Hr.contains("1"))
        XCTAssertTrue(exact3Hr.contains("3") && !exact3Hr.contains("0"))
        XCTAssertTrue(threeHr21Min.contains("3") && threeHr21Min.contains("21"),
                      "Multi-hour remaining duration must show minute precision: \(threeHr21Min)")
    }

    func testReceivedAudioTranscriptionResumesQueuedArrivalsAfterProactiveBudgetStopAndSystemTaskHandoff() async throws {
        let firstStarted = expectation(description: "First grant started")
        let secondStarted = expectation(description: "Second grant started after proactive finite-budget stop")
        let thirdStarted = expectation(description: "Third grant started after system task finished")
        let runner = ReceivedAudioHarness(expectations: [firstStarted, secondStarted, thirdStarted])
        var osGrants = 0
        var osReleases = 0
        var allowNewGrant = true
        let received = ReceivedAudioTranscription(
            begin: { _ in
                osGrants += 1
                return { osReleases += 1 }
            },
            start: { finish in await runner.start(finish) },
            stop: { _, _ in },
            canStartNewGrant: { allowNewGrant }
        )
        received.request()
        await fulfillment(of: [firstStarted], timeout: 5)
        // Concurrent arrival while grant 1 is running, followed by proactive finite-budget stop (.backgroundExpired).
        received.request()
        await runner.finishCurrent(reason: .backgroundExpired)
        await fulfillment(of: [secondStarted], timeout: 5)
        XCTAssertEqual(osGrants, 2, "Queued arrival during proactive budget stop must acquire a fresh OS grant after releasing the first")
        XCTAssertEqual(osReleases, 1)

        // When OS background budget is exhausted, proactive stop releases cleanly without spin-looping.
        allowNewGrant = false
        received.request()
        await runner.finishCurrent(reason: .backgroundExpired)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(osGrants, 2)
        XCTAssertEqual(osReleases, 2)
        XCTAssertFalse(received.isActive)

        // Arrivals during an active BGProcessingTask / BGContinuedProcessingTask drain immediately once the system task finishes.
        allowNewGrant = true
        await received.handOffToSystemTask()
        received.request()
        XCTAssertFalse(received.isActive)
        received.systemTaskFinished()
        await fulfillment(of: [thirdStarted], timeout: 5)
        XCTAssertEqual(osGrants, 3)
        await runner.finishCurrent(reason: .completed)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(osReleases, 3)
    }

    private enum TestFailure: Error { case stopFailed }
}

private actor ReceivedAudioHarness {
    typealias Handle = MoMoAgent.TranscriptionExecutionHandle
    typealias Completion = MoMoAgent.TranscriptionExecutionCompletion
    private let expectations: [XCTestExpectation]
    private var runIndex = 0
    private var currentHandle: Handle?
    private var currentFinish: (@Sendable (Completion) -> Void)?

    init(expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    func start(_ finish: @escaping @Sendable (Completion) -> Void) -> Handle {
        let handle = Handle(id: UUID(), origin: .backgroundProcessing, batchExecution: nil)
        currentHandle = handle
        currentFinish = finish
        if runIndex < expectations.count {
            expectations[runIndex].fulfill()
        }
        runIndex += 1
        return handle
    }

    func finishCurrent(reason: TranscriptionBatchEndReason) {
        guard let handle = currentHandle, let finish = currentFinish else { return }
        currentHandle = nil
        currentFinish = nil
        finish(Completion(execution: handle, reason: reason, failureCode: nil))
    }
}

private actor PreparationGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func open() { continuation?.resume(); continuation = nil }
}

private actor GrantHarness {
    typealias Handle = MoMoAgent.TranscriptionExecutionHandle
    typealias Completion = MoMoAgent.TranscriptionExecutionCompletion
    let handle = Handle(id: UUID(), origin: .continuedProcessing, batchExecution: nil)
    let admitted: XCTestExpectation
    let stopping: XCTestExpectation?
    var finish: (@Sendable (Completion) -> Void)?
    var admission: CheckedContinuation<Handle, Never>?
    var stopBarrier: CheckedContinuation<Void, Never>?
    private(set) var stopReasons: [TranscriptionBatchEndReason] = []

    init(admitted: XCTestExpectation, stopping: XCTestExpectation?) {
        self.admitted = admitted
        self.stopping = stopping
    }

    func start(_ finish: @escaping @Sendable (Completion) -> Void) async -> Handle {
        self.finish = finish
        return await withCheckedContinuation { continuation in
            admission = continuation
            admitted.fulfill()
        }
    }

    func releaseAdmission() { admission?.resume(returning: handle); admission = nil }

    func stop(_ execution: Handle, _ reason: TranscriptionBatchEndReason) async throws {
        stopReasons.append(reason)
        await withCheckedContinuation { continuation in
            stopBarrier = continuation
            stopping?.fulfill()
        }
    }

    func releaseStop() { stopBarrier?.resume(); stopBarrier = nil }
    func deliverLateCompletion() { finish?(Completion(execution: handle, reason: .completed, failureCode: nil)) }
}

private final class PairingHoldProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entered: XCTestExpectation?
    nonisolated(unsafe) private static var workspace: UUID?
    nonisolated(unsafe) private static var nextProbe: XCTestExpectation?
    nonisolated(unsafe) private static var probeResponse: (@Sendable () -> Void)?
    static func holdProbe(_ entered: XCTestExpectation) { lock.withLock { nextProbe = entered } }
    static func releaseProbe() {
        let response = lock.withLock { let response = probeResponse; probeResponse = nil; return response }
        response?()
    }
    static func observe(_ expectation: XCTestExpectation) {
        lock.withLock { entered = expectation; workspace = nil; nextProbe = nil; probeResponse = nil }
    }
    static func respond(workspace: UUID) {
        lock.withLock { self.workspace = workspace; entered = nil; nextProbe = nil; probeResponse = nil }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let workspace = Self.lock.withLock { Self.entered?.fulfill(); Self.entered = nil; return Self.workspace }
        guard let workspace else { return }
        if request.url?.path == "/v1/capabilities", Self.lock.withLock({
            guard let next = Self.nextProbe else { return false }
            Self.nextProbe = nil
            Self.probeResponse = { [self] in
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil,
                                                                     headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
            }
            next.fulfill(); return true
        }) { return }
        let body = request.url?.path == "/v1/status"
            ? "{\"workspace_id\":\"\(workspace)\",\"source_sync\":true,\"memory_writer\":\"SuperAgent\"}"
            : #"{"features":{"run_submission":true,"runs_idempotency":{"supported":true,"durable":true}}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                             headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
