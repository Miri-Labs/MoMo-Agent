import CSQLite
import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct RecordingLedgerWriteFailureTests {
    @Test func sqliteFullReceiptTransactionPreservesUnacknowledgedAudioAndOriginalError() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let original = fixture.envelope.manifest
        var chunks: [RecordedChunk] = []
        var receipts: [Receipt] = []
        // Bounded real ledger preparation: 32 tiny PCM chunks, below 11 KiB of audio.
        // No fabricated receipts are inserted directly into SQLite.
        for offset in 0..<32 {
            let envelope = try ManifestEnvelope(manifest: ChunkManifest(
                sessionID: original.sessionID, epochID: original.epochID,
                sourceDeviceID: original.sourceDeviceID, sourceBuild: "ledger-quota-tests",
                sequence: Int64(offset), frames: FrameRange(start: Int64(offset * 160), count: 160),
                timebaseHz: 16_000, wallClockAnchor: original.wallClockAnchor, timezoneOffset: original.timezoneOffset,
                codec: original.codec, sampleRate: original.sampleRate, channels: original.channels,
                decodedFrameCount: original.decodedFrameCount, byteCount: original.byteCount,
                audioSHA256: original.audioSHA256, sourceKind: .fixture))
            chunks.append(try await store.sealChunk(audioAt: fixture.source, envelope: envelope))
            receipts.append(try Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
                chunkID: envelope.manifest.chunkID, audioSHA256: envelope.manifest.audioSHA256,
                manifestSHA256: envelope.manifestSHA256))
        }
        let retained = try await store.exerciseReceiptQuotaFailure(chunks: chunks, receipts: receipts)
        let reopened = try fixture.store()
        #expect(try await reopened.pendingChunkCount() == retained.count)
        #expect(Set(try await reopened.pendingChunks().map(\.envelope.manifest.chunkID)) == Set(retained))
        for chunk in try await reopened.pendingChunks() {
            #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        }
    }
}

private extension RecordingStore {
    // Keep the non-Sendable database and its quota changes on the owning actor.
    func exerciseReceiptQuotaFailure(chunks: [RecordedChunk], receipts: [Receipt]) throws -> [UUID] {
        let originalMaximum = try #require(database.rows("PRAGMA max_page_count") { sqlite3_column_int64($0, 0) }.first)
        defer {
            do { try database.execute("PRAGMA max_page_count=\(originalMaximum)") }
            catch { Issue.record("Could not restore disposable ledger page limit: \(error)") }
        }
        let currentPages = try #require(database.rows("PRAGMA page_count") { sqlite3_column_int64($0, 0) }.first)
        try database.execute("PRAGMA max_page_count=\(currentPages)")
        #expect(try database.rows("PRAGMA max_page_count") { sqlite3_column_int64($0, 0) }.first == currentPages)
        var successful: [ReceiptApplied] = []
        var failedIndex: Int?
        for (index, receipt) in receipts.enumerated() {
            do { successful.append(try applyReceipt(receipt)) }
            catch let error as RecordingDatabaseError {
                failedIndex = index
                #expect(error.code == SQLITE_FULL, "Receipt error must retain SQLITE_FULL after automatic rollback")
                break
            }
        }
        let failed = try #require(failedIndex, "The bounded real receipt writes must exceed the fixed page budget")
        let failedChunk = chunks[failed]
        #expect(try chunk(id: failedChunk.envelope.manifest.chunkID)?.state == .ready)
        #expect(try pendingReceiptApplications() == successful)
        #expect(try pendingChunkCount() == chunks.count - successful.count)
        for chunk in chunks {
            #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        }
        #expect(try database.rows("PRAGMA integrity_check") { RecordingDatabase.text($0, 0) }.first == "ok")
        #expect(try database.rows("PRAGMA foreign_key_check") { _ in true }.isEmpty)
        try database.execute("PRAGMA max_page_count=\(originalMaximum)")

        let recovered = try applyReceipt(receipts[failed])
        #expect(recovered.receipt == receipts[failed])
        #expect(try applyReceipt(receipts[failed]) == recovered)
        #expect(try pendingReceiptApplications() == successful + [recovered])
        let cleaned = try cleanupAcknowledgedChunks()
        #expect(Set(cleaned) == Set(chunks.prefix(failed + 1).map(\.envelope.manifest.chunkID)))
        let remaining = Array(chunks.dropFirst(failed + 1))
        for chunk in remaining {
            #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        }
        #expect(try pendingChunkCount() == remaining.count)
        #expect(try database.rows("PRAGMA integrity_check") { RecordingDatabase.text($0, 0) }.first == "ok")
        return remaining.map(\.envelope.manifest.chunkID)
    }
}
