import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct AudioTransferBatchTests {
    @Test func processExitReleasesAShortBatchWithoutAStopButton() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let store = try f.store()
        let m = f.envelope.manifest
        try await store.saveIntent(.recording, sessionID: m.sessionID)
        try await store.beginEpoch(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID)
        let chunk = try await add(0, at: 1_000.01, fixture: f, store: store)
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_001)) == 0)
        let reopened = try f.store()
        _ = try await reopened.recoverInterruptedEpochs()
        let admitted = try await reopened.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_002))
        #expect(admitted == 1)
        #expect(try await reopened.pendingChunkBatch(after: 0, through: admitted).map(\.chunk.envelope) == [chunk.envelope])
        #expect(try await reopened.latestActiveSession() == nil)
    }

    @Test func aMarkAlsoReleasesItsNotYetSealedAudioAfterRestart() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let store = try f.store()
        _ = try await add(0, at: 1_000.01, fixture: f, store: store)
        let m = f.envelope.manifest
        try await store.recordMark(CaptureMark(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, sourceFrame: 160))
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_001), force: true) == 1)
        _ = try await add(1, at: 1_010.01, fixture: f, store: store)
        let reopened = try f.store()
        #expect(try await reopened.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_011)) == 2)
        _ = try await add(2, at: 1_020.01, fixture: f, store: reopened)
        #expect(try await reopened.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_021)) == 2)
    }

    @Test func clockMovingBackwardsCannotHoldAudioUntilTheOldClockCatchesUp() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let store = try f.store()
        _ = try await add(0, at: 10_000, fixture: f, store: store)
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_000)) == 1)
    }
    @Test func fiveMinuteAdmissionSurvivesRestartAndDrainsWithoutAdmittingNewChunks() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let store = try f.store()
        for index in 0..<4 { _ = try await add(index, at: 1_000.01 + Double(index * 60), fixture: f, store: store) }
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_299)) == 0)
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_300)) == 4)
        _ = try await add(4, at: 1_300.01, fixture: f, store: store)
        let reopened = try f.store()
        let admitted = try await reopened.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_301))
        #expect(admitted == 4)
        #expect(try await reopened.pendingChunkBatch(after: 0, through: admitted).count == 4)
        #expect(try await reopened.pendingChunkBatch(after: 4, through: admitted).isEmpty)
        #expect(try await reopened.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_599)) == 4)
        #expect(try await reopened.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_600)) == 5)
    }

    @Test func viewingAndEndingCanReleaseAShortBatchAndOldBacklogDoesNotWait() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let store = try f.store()
        _ = try await add(0, at: 1_000.01, fixture: f, store: store)
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_001), force: true) == 1)
        _ = try await add(1, at: 1_001.01, fixture: f, store: store)
        let m = f.envelope.manifest
        try await store.beginEpoch(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID)
        try await store.recordEpochEnded(CaptureEpochEnded(sessionID: m.sessionID, epochID: m.epochID,
            sourceDeviceID: m.sourceDeviceID, endFrame: 320, reason: .stopped))
        #expect(try await store.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 1_002)) == 2)
        let backlog = try f.store("backlog")
        _ = try await add(0, at: 1_000.01, fixture: f, store: backlog)
        #expect(try await backlog.audioTransferBatchEnd(now: Date(timeIntervalSince1970: 100_000)) == 1)
    }

    @Test func reconciliationInventoryOnlyIncludesTheReleasedBatch() async throws {
        let f = try RecordingFixture(); defer { f.clean() }
        let store = try f.store()
        let m = f.envelope.manifest
        try await store.bindReceiver(deviceID: f.receiverID, libraryInstanceID: f.libraryID)
        let first = try await add(0, at: 1_000.01, fixture: f, store: store)
        _ = try await add(1, at: 1_060.01, fixture: f, store: store)
        let request = try #require(await store.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID, through: 1))
        #expect(request.items.map(\.chunkID) == [first.envelope.manifest.chunkID])
    }

    private func add(_ index: Int, at sealedAt: TimeInterval, fixture f: RecordingFixture, store: RecordingStore) async throws -> RecordedChunk {
        let m = f.envelope.manifest
        let manifest = try ChunkManifest(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID,
            sourceBuild: "batch-test", sequence: Int64(index), frames: FrameRange(start: Int64(index * 160), count: 160),
            timebaseHz: m.timebaseHz, wallClockAnchor: m.wallClockAnchor, timezoneOffset: m.timezoneOffset,
            codec: m.codec, sampleRate: m.sampleRate, channels: m.channels, decodedFrameCount: 160,
            byteCount: m.byteCount, audioSHA256: m.audioSHA256, sealedAt: Date(timeIntervalSince1970: sealedAt), sourceKind: .fixture)
        return try await store.sealChunk(audioAt: f.source, envelope: ManifestEnvelope(manifest: manifest))
    }
}
