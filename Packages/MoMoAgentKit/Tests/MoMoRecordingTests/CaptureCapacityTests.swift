import Foundation
import Synchronization
import Testing
import MoMoContracts
@testable import MoMoRecording

@Suite(.serialized)
struct CaptureCapacityTests {
    @Test func admissionUsesMeasuredLedgerAndRejectsUnknownCapacity() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let budget = try await store.captureCapacityBudget()
        #expect(budget.nextAudioBytes == 960_000 * 4)
        #expect(budget.closingAndCopyBytes == budget.nextAudioBytes)
        #expect(budget.metadataBytes > 0)
        let exact = CaptureCapacityReader { _ in budget.requiredBytes }
        #expect(try await store.checkCaptureCapacity(reader: exact).availableBytes == budget.requiredBytes)
        let insufficient = CaptureCapacityReader { _ in budget.requiredBytes - 1 }
        do {
            _ = try await store.checkCaptureCapacity(reader: insufficient)
            Issue.record("Admission must reject a capacity below the complete write budget")
        } catch CaptureCapacityError.insufficient(let snapshot) {
            #expect(snapshot.stage == .starting)
            #expect(snapshot.availableBytes == snapshot.budget.requiredBytes - 1)
        }
        await #expect(throws: CaptureCapacityError.unavailable) {
            try await store.checkCaptureCapacity(reader: CaptureCapacityReader { _ in throw CocoaError(.fileReadNoPermission) })
        }
        await #expect(throws: CaptureCapacityError.unavailable) {
            try await store.checkCaptureCapacity(reader: CaptureCapacityReader { _ in -1 })
        }
        #expect(try await store.pendingChunks().isEmpty)
        #expect(try await store.latestActiveSession() == nil)
    }

    @Test func liveVolumeCapacityIsReadWithoutAllocatingDiskPressure() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let snapshot = try await store.checkCaptureCapacity()
        #expect(snapshot.availableBytes >= snapshot.budget.requiredBytes)
        #expect(snapshot.budget.requiredBytes > 0)
    }

    @Test func firstChunkRefusalCreatesNeitherAudioNorDraft() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
        pair.continuation.yield(CapturedAudioBlock(mono: Array(repeating: 0.02, count: 1_024), sampleTime: 0,
            uptime: 1, wallClock: Date(), normalizedLevel: 0.02))
        pair.continuation.finish()
        let directory = fixture.root.appendingPathComponent("encoder")
        let manifest = fixture.envelope.manifest
        do {
            _ = try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
                directory: directory, sessionID: manifest.sessionID, epochID: manifest.epochID,
                sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "capacity-tests", sourceKind: .fixture,
                store: store, capacityReader: CaptureCapacityReader { _ in 0 }, progress: { _ in })
            Issue.record("Expected capacity refusal before creating the first audio file")
        } catch CaptureCapacityError.insufficient(let snapshot) { #expect(snapshot.stage == .starting) }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        #expect(try await store.pendingChunks().isEmpty)
    }

    @Test func rotationRefusalPreservesTheChunkClosedInsideTheSameInputBlock() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let manifest = fixture.envelope.manifest
        try await store.saveIntent(.recording, sessionID: manifest.sessionID)
        try await store.beginEpoch(sessionID: manifest.sessionID, epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID)
        let calls = CapacityReadCount()
        // Platform fault injection only: no quota, synthetic full volume, or repeated audio file is used.
        let capacity = CaptureCapacityReader { _ in
            calls.next() == 1 ? Int64.max : 0
        }
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
        for block in 0..<3 {
            let frames = (0..<8_192).map { Float(sin(Double(block * 8_192 + $0) * 0.043)) * 0.04 }
            pair.continuation.yield(CapturedAudioBlock(mono: frames, sampleTime: Int64(block * 8_192),
                uptime: Double(block + 1), wallClock: Date(), normalizedLevel: 0.04))
        }
        pair.continuation.finish()
        let directory = fixture.root.appendingPathComponent("encoder")
        let snapshot: CaptureCapacitySnapshot
        do {
            _ = try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
                directory: directory, sessionID: manifest.sessionID, epochID: manifest.epochID,
                sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "capacity-tests", sourceKind: .fixture,
                store: store, capacityReader: capacity, targetSeconds: 1, progress: { _ in })
            Issue.record("Expected admission refusal before opening a second AAC container")
            return
        } catch CaptureCapacityError.insufficient(let value) { snapshot = value }
        #expect(snapshot.stage == .rotating && snapshot.availableBytes == 0)
        #expect(calls.value == 2)
        let chunks = try await store.pendingChunks()
        let chunk = try #require(chunks.first)
        #expect(chunks.count == 1)
        #expect(chunk.envelope.manifest.frames.count == 16_000)
        #expect(chunk.envelope.manifest.byteCount < snapshot.budget.nextAudioBytes)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)

        let event = CaptureDiagnostic(code: .lowSpace, sessionID: manifest.sessionID, epochID: manifest.epochID,
            observedFrames: 16_000, inputSampleRate: 16_000, capacity: snapshot)
        try await store.recordCapacityStop(event)
        _ = try await store.recordEpochInterruption(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: manifest.sourceDeviceID, lastObservedFrame: 16_000, reason: .failed)
        #expect(try await store.cleanupAcknowledgedChunks().isEmpty)
        let reopened = try fixture.store()
        #expect(try await reopened.intent(sessionID: manifest.sessionID) == .paused)
        let persistedEvent = try #require(await reopened.captureDiagnostics().first)
        // WireJSON persists millisecond timestamps, rather than Date's submillisecond precision.
        #expect(try WireJSON.encode(persistedEvent) == WireJSON.encode(event))
        #expect(abs(persistedEvent.timestamp.timeIntervalSince(event.timestamp)) < 0.001)
        #expect(try await reopened.pendingChunks().count == 1)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        var restored = CaptureState()
        restored.restore(intent: try #require(await reopened.intent(sessionID: manifest.sessionID)))
        let automaticResume = restored.resumeAfterInterruption(systemAllows: true)
        #expect(automaticResume == nil)
        try await reopened.saveIntent(.stopped, sessionID: manifest.sessionID)
        try await reopened.recordCapacityStop(event)
        #expect(try await reopened.intent(sessionID: manifest.sessionID) == .stopped)
    }

    @Test func anAdmittedShortTailStillSealsWithoutOpeningAnotherContainer() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let calls = CapacityReadCount()
        let reader = CaptureCapacityReader { _ in
            calls.next() == 1 ? Int64.max : 0
        }
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
        pair.continuation.yield(CapturedAudioBlock(mono: Array(repeating: 0.03, count: 8_000), sampleTime: 0,
            uptime: 1, wallClock: Date(), normalizedLevel: 0.03))
        pair.continuation.finish()
        let manifest = fixture.envelope.manifest
        let count = try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
            directory: fixture.root.appendingPathComponent("encoder"), sessionID: manifest.sessionID,
            epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "capacity-tests",
            sourceKind: .fixture, store: store, capacityReader: reader, targetSeconds: 1, progress: { _ in })
        #expect(count == 8_000)
        #expect(calls.value == 1)
        #expect(try await store.pendingChunks().first?.envelope.manifest.frames.count == 8_000)
    }

    @Test func diagnosticsAreBoundedAndMigrationKeepsUnconfirmedAudio() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        // Recreate the immediately preceding schema, with its real chunk ledger and original audio intact.
        let oldDatabase = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try removeSchemaFiveTables(oldDatabase)
        try oldDatabase.execute("DROP TABLE capture_diagnostics")
        try oldDatabase.execute("PRAGMA user_version = 3")
        let migrated = try fixture.store()
        var last: CaptureDiagnostic?
        for index in 0..<(RecordingStore.diagnosticLimit + 5) {
            let event = CaptureDiagnostic(code: .inputStalled, sessionID: fixture.envelope.manifest.sessionID,
                observedFrames: Int64(index))
            try await migrated.recordDiagnostic(event)
            last = event
        }
        let reopened = try fixture.store()
        let diagnostics = try await reopened.captureDiagnostics()
        #expect(diagnostics.count == RecordingStore.diagnosticLimit)
        let latest = try #require(diagnostics.first)
        let expectedLatest = try #require(last)
        #expect(try WireJSON.encode(latest) == WireJSON.encode(expectedLatest))
        #expect(abs(latest.timestamp.timeIntervalSince(expectedLatest.timestamp)) < 0.001)
        #expect(diagnostics.last?.observedFrames == 5)
        #expect(try await reopened.pendingChunkCount() == 1)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        let payload = String(decoding: try WireJSON.encode(diagnostics), as: UTF8.self)
        #expect(!payload.contains(fixture.root.path) && !payload.contains("input.pcm"))
    }
}

@available(macOS 15, iOS 18, watchOS 11, *)
private final class CapacityReadCount: Sendable {
    private let count = Mutex(0)
    func next() -> Int { count.withLock { value in value += 1; return value } }
    var value: Int { count.withLock { $0 } }
}
