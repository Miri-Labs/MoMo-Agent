import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct RecordingQueueIndexTests {
    @Test func repeatedSummariesDecodeOnlyChangedRowsAndKeepSealedCoverage() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), original = fixture.envelope.manifest
        var files: [ManifestEnvelope] = []
        for sequence in 0..<2_000 {
            files.append(try ManifestEnvelope(manifest: ChunkManifest(sessionID: original.sessionID,
                epochID: original.epochID, sourceDeviceID: original.sourceDeviceID, sourceBuild: "queue-test",
                sequence: Int64(sequence), frames: FrameRange(start: Int64(sequence) * 160, count: 160),
                timebaseHz: 16_000, wallClockAnchor: original.wallClockAnchor, timezoneOffset: 0, codec: .pcmInt16,
                sampleRate: 16_000, channels: 1, decodedFrameCount: 160, byteCount: original.byteCount,
                audioSHA256: original.audioSHA256, sourceKind: .fixture)))
        }
        try await store.insertQueueFixtures(files)
        let first = try await store.queueSummary(sessionID: original.sessionID)
        #expect(first.pendingChunkCount == 2_000)
        #expect(abs(first.pendingDuration - 20) < 0.000_001)
        #expect(first.pendingBytes == 2_000 * original.byteCount)
        for _ in 0..<100 { _ = try await store.queueSummary(sessionID: original.sessionID) }
        #expect(await store.queueDecodedRows == 2_000)
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let receipt = try Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
            chunkID: files[0].manifest.chunkID, audioSHA256: original.audioSHA256, manifestSHA256: files[0].manifestSHA256)
        _ = try await store.applyReceipt(receipt)
        _ = try await store.applyReceipt(receipt)
        let after = try await store.queueSummary(sessionID: original.sessionID)
        #expect(after.pendingChunkCount == 1_999 && after.pendingBytes == 1_999 * original.byteCount)
        #expect(abs(after.pendingDuration - 19.99) < 0.000_001)
        #expect(after.sealedDuration == first.sealedDuration)
        #expect(await store.queueDecodedRows == 2_001)
        let reopened = try fixture.store()
        let restored = try await reopened.queueSummary(sessionID: original.sessionID)
        #expect(restored.pendingChunkCount == after.pendingChunkCount && restored.pendingBytes == after.pendingBytes)
        #expect(restored.pendingDuration == after.pendingDuration && restored.sealedDuration == after.sealedDuration)
    }

    @Test func idleSummaryDoesNotDecodeOrRetainAcknowledgedHistory() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        _ = try await store.applyReceipt(fixture.receipt())
        let idle = try await store.queueSummary(sessionID: nil)
        #expect(idle.pendingChunkCount == 0 && idle.sealedDuration == 0)
        #expect(await store.queueDecodedRows == 0)
        let active = try await store.queueSummary(sessionID: fixture.envelope.manifest.sessionID)
        #expect(active.sealedDuration > 0 && active.pendingChunkCount == 0)
        #expect(await store.queueDecodedRows == 1)
        let idleAgain = try await store.queueSummary(sessionID: nil)
        #expect(idleAgain.sealedDuration == 0 && idleAgain.pendingChunkCount == 0)
        #expect(await store.queueDecodedRows == 1)
    }

    @Test func rollbackExternalConnectionAndDeletionDoNotLeaveStaleTotals() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), manifest = fixture.envelope.manifest
        _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let initial = try await store.queueSummary(sessionID: manifest.sessionID)
        try await store.rollbackQueueChange()
        let rolledBack = try await store.queueSummary(sessionID: manifest.sessionID)
        #expect(rolledBack.pendingChunkCount == 1 && rolledBack.pendingBytes == initial.pendingBytes)
        let database = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try database.execute("UPDATE chunks SET state='missing'")
        let missing = try await store.queueSummary(sessionID: manifest.sessionID)
        #expect(missing.pendingChunkCount == 0 && missing.pendingBytes == 0 && missing.pendingDuration == 0)
        #expect(missing.sealedDuration == initial.sealedDuration)
        try database.execute("UPDATE chunks SET state='ready'")
        #expect(try await store.queueSummary(sessionID: manifest.sessionID).pendingChunkCount == 1)
        try await store.removeQueueFixture()
        let deleted = try await store.queueSummary(sessionID: manifest.sessionID)
        #expect(deleted.pendingChunkCount == 0 && deleted.sealedDuration == 0)
        try await store.insertQueueFixtures([fixture.envelope]) // SQLite can reuse the deleted rowid.
        #expect(try await store.queueSummary(sessionID: manifest.sessionID).pendingChunkCount == 1)
    }
}

private extension RecordingStore {
    func insertQueueFixtures(_ files: [ManifestEnvelope]) throws {
        try database.transaction {
            for file in files {
                try database.execute("INSERT INTO chunks(id,session_id,envelope,manifest_hash,state) VALUES(?,?,?,?,'ready')",
                    [.text(file.manifest.chunkID.uuidString), .text(file.manifest.sessionID.uuidString),
                     .blob(try WireJSON.encode(file)), .text(file.manifestSHA256)])
            }
        }
    }

    func rollbackQueueChange() throws {
        enum Probe: Error { case rollback }
        do {
            try database.transaction {
                try database.execute("UPDATE chunks SET state='acknowledged'")
                throw Probe.rollback
            }
        } catch Probe.rollback { }
    }

    func removeQueueFixture() throws { try database.execute("DELETE FROM chunks") }
}
