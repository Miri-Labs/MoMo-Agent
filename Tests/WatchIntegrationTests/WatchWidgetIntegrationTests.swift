import Foundation
import XCTest
import MoMoContracts
import MoMoRecording
@testable import MoMoAgentWatch

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class WatchWidgetIntegrationTests: XCTestCase {
    func testRestoredRecordingReportsIdleAndCurrentStartControlResumesTheSameSession() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let runtime = fixture.runtime, sessionID = UUID()
        let store = try RecordingStore(rootURL: fixture.rootURL)
        try await store.saveIntent(.recording, sessionID: sessionID)
        let (snapshots, continuation) = AsyncStream.makeStream(of: WatchWidgetSnapshot.self)
        defer { continuation.finish() }
        runtime.widgetPublisher = { continuation.yield($0) }
        addTeardownBlock { if await runtime.sessionID != nil { try await runtime.stop() } }
        await runtime.bootstrap()
        var iterator = snapshots.makeAsyncIterator()
        let first = await iterator.next()
        let initial = try XCTUnwrap(first)
        XCTAssertEqual(initial.activity, .idle)
        XCTAssertEqual(initial.sessionID, sessionID)
        XCTAssertNil(initial.lastSampleAt)
        let performed = try await runtime.performWidgetRequest(initial.request(.start))
        XCTAssertTrue(performed)
        XCTAssertEqual(runtime.sessionID, sessionID)
        let deadline = ContinuousClock.now + .seconds(15)
        while runtime.captureState.capturedFrames == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(runtime.captureState.capturedFrames, 0)
        XCTAssertEqual(runtime.captureState.activity, .recording)
    }

    func testLocalStatePublishesWithoutPhoneConnectivityAndColdControlsCannotRestartCapture() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let (snapshots, continuation) = AsyncStream.makeStream(of: WatchWidgetSnapshot.self)
        defer { continuation.finish() }
        fixture.runtime.widgetPublisher = { snapshot in continuation.yield(snapshot) }
        await fixture.runtime.bootstrap()
        var iterator = snapshots.makeAsyncIterator()
        let first = await iterator.next()
        let initial = try XCTUnwrap(first)
        XCTAssertEqual(initial.activity, .idle)
        XCTAssertTrue(initial.isFresh(at: Date()))
        XCTAssertTrue(fixture.runtime.ready)
        let stale = WatchWidgetRequest(action: .start, runtimeID: UUID(), generation: initial.generation)
        let performed = try await fixture.runtime.performWidgetRequest(stale)
        XCTAssertFalse(performed)
        XCTAssertNil(fixture.runtime.sessionID)
        XCTAssertEqual(fixture.runtime.captureState.activity, .idle)
        let opened = try await fixture.runtime.performWidgetRequest(WatchWidgetRequest())
        XCTAssertTrue(opened)
        XCTAssertNil(fixture.runtime.sessionID)
    }

    func testWidgetFileRoundTripAndCorruptionAreIndependentFromRecordingLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchWidgetStore(url: directory.appendingPathComponent("capture-widget.json"))
        XCTAssertNil(try store.read())
        let snapshot = WatchWidgetSnapshot(runtimeID: UUID(), generation: 2, observedAt: Date(),
            sessionID: UUID(), activity: .paused, capturedDuration: 70, pendingChunkCount: 2, lastSampleAt: nil)
        try store.write(snapshot)
        XCTAssertEqual(try store.read(), snapshot)
        try Data("invalid".utf8).write(to: store.url, options: .atomic)
        XCTAssertThrowsError(try store.read())
        try store.write(snapshot)
        XCTAssertEqual(try store.read(), snapshot)
    }

    func testOutOfOrderWidgetPublicationsKeepTheNewerObservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WatchWidgetStore(url: directory.appendingPathComponent("capture-widget.json"))
        let publisher = WatchWidgetPublisher(store: store)
        let runtimeID = UUID(), sessionID = UUID(), date = Date()
        let newer = WatchWidgetSnapshot(runtimeID: runtimeID, generation: 3, observedAt: date,
            sessionID: sessionID, activity: .paused, capturedDuration: 73, pendingChunkCount: 2,
            lastSampleAt: nil, revision: 2)
        let older = WatchWidgetSnapshot(runtimeID: runtimeID, generation: 2, observedAt: date,
            sessionID: sessionID, activity: .recording, capturedDuration: 70, pendingChunkCount: 1,
            lastSampleAt: date, revision: 1)
        await publisher.publish(newer)
        await publisher.publish(older)
        XCTAssertEqual(try store.read(), newer)
    }

    func testSuspendedWidgetWriterDoesNotBlockRuntimeBootstrap() async throws {
        let fixture = try WatchComposition.makeSimulatorTest(runID: UUID())
        let gate = WidgetWriterGate()
        fixture.runtime.widgetPublisher = { _ in await gate.wait() }
        await fixture.runtime.bootstrap()
        XCTAssertTrue(fixture.runtime.ready)
        XCTAssertNil(fixture.runtime.sessionID)
        await gate.release()
    }
}

private actor WidgetWriterGate {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        for continuation in continuations { continuation.resume() }
        continuations.removeAll()
    }
}

#endif
