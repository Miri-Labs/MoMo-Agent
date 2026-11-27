import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct MacAudioUploadStoreTests {
    /// Slice 1 (iPhone side): Out-of-order Watch chunk arrival MUST preserve immutable `manifest.sequence`
    /// rather than dynamically renumbering via ROW_NUMBER() when earlier chunks arrive later.
    @Test func outOfOrderArrivalKeepsImmutableManifestSequence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let baseTime = Date()

        // Minute 2 (sequence = 1) arrives BEFORE minute 1 (sequence = 0)
        let chunk2ID = UUID()
        let env2 = try fixture.envelope(
            chunkID: chunk2ID,
            startFrame: 16_000,
            frameCount: 16_000,
            sequence: 1,
            sealedAt: baseTime.addingTimeInterval(60)
        )
        _ = try await store.commitReceivedChunk(try fixture.deliver(env2, to: store))

        let pendingFirst = try await store.pendingMacAudioUploads(limit: 8)
        #expect(pendingFirst.count == 1)
        #expect(pendingFirst[0].chunkID == chunk2ID)
        #expect(pendingFirst[0].chunkSeq == 1, "Out-of-order chunk must keep its immutable manifest.sequence (1), not 0")

        // Minute 1 (sequence = 0) arrives later
        let chunk1ID = UUID()
        let env1 = try fixture.envelope(
            chunkID: chunk1ID,
            startFrame: 0,
            frameCount: 16_000,
            sequence: 0,
            sealedAt: baseTime
        )
        _ = try await store.commitReceivedChunk(try fixture.deliver(env1, to: store))

        let pendingBoth = try await store.pendingMacAudioUploads(limit: 8)
        let seqByID = Dictionary(uniqueKeysWithValues: pendingBoth.map { ($0.chunkID, $0.chunkSeq) })
        #expect(seqByID[chunk1ID] == 0)
        #expect(seqByID[chunk2ID] == 1)
    }

    /// Slice 4: Caching a partial Mac transcript covering only chunk 1 of a 3-chunk recording
    /// MUST NOT prematurely mark uploaded chunks 2 and 3 as complete in `transcription_jobs`.
    @Test func partialTranscriptDoesNotPrematurelyCompleteUntranscribedChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let baseAnchor = Date(timeIntervalSince1970: 1_790_000_000)

        var chunkIDs: [UUID] = []
        for idx in 0..<3 {
            let cid = UUID()
            chunkIDs.append(cid)
            let env = try fixture.envelope(
                chunkID: cid,
                startFrame: Int64(idx * 16_000),
                frameCount: 16_000,
                sequence: Int64(idx),
                sealedAt: baseAnchor.addingTimeInterval(Double(idx + 1))
            )
            _ = try await store.commitReceivedChunk(try fixture.deliver(env, to: store))
            try await store.markMacAudioChunkUploaded(
                chunkID: cid,
                remoteSHA256: env.manifest.audioSHA256,
                remoteSourceID: "\(store.libraryInstanceID.uuidString.lowercased())/\(fixture.sessionID.uuidString.lowercased())"
            )
        }

        // Mac has only transcribed chunk 0 so far (0..0.9s); chunks 1 and 2 are still queued on Mac!
        try await store.cacheMacRemoteTranscript(
            sessionID: fixture.sessionID,
            spans: [
                MacRemoteTranscriptSpanInput(
                    id: UUID(),
                    text: "第一段话刚转完。",
                    recordedAt: baseAnchor.addingTimeInterval(0.1),
                    endAt: baseAnchor.addingTimeInterval(0.9),
                    speaker: "我",
                    isOwner: true,
                    timezoneOffset: 28_800
                )
            ],
            macGeneration: 1,
            macVersion: 2
        )

        // Chunks 1 and 2 MUST remain unsettled so AudioUploadCoordinator keeps polling batch-status for them!
        let unsettled = Set(try await store.uploadedUnsettledMacAudioChunkIDs(limit: 16))
        #expect(!unsettled.contains(chunkIDs[0]), "Chunk 0 covered by transcript should be settled")
        #expect(unsettled.contains(chunkIDs[1]), "Chunk 1 not yet transcribed must stay unsettled")
        #expect(unsettled.contains(chunkIDs[2]), "Chunk 2 not yet transcribed must stay unsettled")

        // Once Mac batch-status explicitly reports silent/done for chunks 1 and 2, they settle cleanly.
        let changed = try await store.markMacAudioChunksStatus([chunkIDs[1]: "silent", chunkIDs[2]: "done"])
        #expect(changed == 2)
        let unsettledAfter = try await store.uploadedUnsettledMacAudioChunkIDs(limit: 16)
        #expect(unsettledAfter.isEmpty)
    }

    /// Slice 2 (Archive side): Transient failures enter exponential backoff and permanent failures
    /// never head-of-line block older healthy chunks.
    @Test func backoffAndPermanentFailuresDoNotBlockHealthyChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        let olderID = UUID()
        let newestTransientID = UUID()
        let newestPermanentID = UUID()

        let envOlder = try fixture.envelope(chunkID: olderID, startFrame: 0, frameCount: 16_000, sequence: 0, sealedAt: t0)
        let envTrans = try fixture.envelope(chunkID: newestTransientID, startFrame: 16_000, frameCount: 16_000, sequence: 1, sealedAt: t0.addingTimeInterval(60))
        let envPerm = try fixture.envelope(chunkID: newestPermanentID, startFrame: 32_000, frameCount: 16_000, sequence: 2, sealedAt: t0.addingTimeInterval(120))

        for env in [envOlder, envTrans, envPerm] {
            _ = try await store.commitReceivedChunk(try fixture.deliver(env, to: store))
        }

        // Permanent failure on newest chunk + transient failure on second-newest
        try await store.markMacAudioChunkFailed(chunkID: newestPermanentID, error: "HTTP 422 corrupt", permanent: true, now: t0)
        try await store.markMacAudioChunkFailed(chunkID: newestTransientID, error: "HTTP 503", permanent: false, now: t0, retryDelay: 30)

        // Immediately after failure (t0 + 1s): ONLY older healthy chunk is eligible!
        let eligibleNow = try await store.pendingMacAudioUploads(limit: 8, now: t0.addingTimeInterval(1))
        #expect(eligibleNow.map(\.chunkID) == [olderID])

        // After 31s backoff expires: transient chunk becomes eligible again; permanent chunk stays skipped!
        let eligibleLater = try await store.pendingMacAudioUploads(limit: 8, now: t0.addingTimeInterval(31))
        #expect(eligibleLater.map(\.chunkID) == [newestTransientID, olderID])

        // Resetting transient backoff immediately revives transient chunk without reviving permanent chunk.
        try await store.markMacAudioChunkFailed(chunkID: newestTransientID, error: "HTTP 503", permanent: false, now: t0.addingTimeInterval(31), retryDelay: 600)
        #expect(try await store.pendingMacAudioUploads(limit: 8, now: t0.addingTimeInterval(32)).map(\.chunkID) == [olderID])
        try await store.resetTransientMacAudioUploadBackoff()
        #expect(try await store.pendingMacAudioUploads(limit: 8, now: t0.addingTimeInterval(32)).map(\.chunkID) == [newestTransientID, olderID])

        let counts = try await store.macAudioUploadCounts()
        #expect(counts.pending == 1)
        #expect(counts.failed == 1)
        #expect(counts.permanentFailed == 1)
    }

    /// Slice 5 (Archive side): Synced Mac source revisions persist across ArchiveStore restarts.
    @Test func syncedSourceRevisionsPersistAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        try await store.setMacSyncedSourceRevision(sourceID: "lib/sess1", revision: "1:4:abc:0")
        let reopened = try fixture.store()
        #expect(try await reopened.macSyncedSourceRevisions() == ["lib/sess1": "1:4:abc:0"])
        try await reopened.clearMacSyncedSourceRevisions()
        #expect(try await reopened.macSyncedSourceRevisions().isEmpty)
    }

    /// Untranscribed live recordings MUST jump ahead of already-transcribed historical backfill chunks.
    @Test func untranscribedChunksPrioritizedAheadOfAlreadyTranscribedBackfill() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        let olderUntranscribed = UUID()
        let newerAlreadyTranscribed = UUID()
        let envOlder = try fixture.envelope(chunkID: olderUntranscribed, startFrame: 0, frameCount: 16_000, sequence: 0, sealedAt: t0)
        let envNewer = try fixture.envelope(chunkID: newerAlreadyTranscribed, startFrame: 16_000, frameCount: 16_000, sequence: 1, sealedAt: t0.addingTimeInterval(60))
        _ = try await store.commitReceivedChunk(try fixture.deliver(envOlder, to: store))
        _ = try await store.commitReceivedChunk(try fixture.deliver(envNewer, to: store))

        // Mark newer chunk's legacy transcription job as already complete while older chunk is untranscribed.
        _ = try await store.markMacAudioChunksStatus([newerAlreadyTranscribed: "done"])

        let ordered = try await store.pendingMacAudioUploads(limit: 8)
        #expect(ordered.map(\.chunkID) == [olderUntranscribed, newerAlreadyTranscribed])
    }
}
