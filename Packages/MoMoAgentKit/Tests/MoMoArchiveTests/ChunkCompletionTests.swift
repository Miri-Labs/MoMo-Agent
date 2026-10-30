import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ChunkCompletionTests {
    @Test func completionPreservesGapsPendingContextAndSupersededJobs() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("chunk-completion".utf8))
        var chunks: [ManifestEnvelope] = []
        for index in 0..<5 {
            let chunk = try fixture.envelope(startFrame: Int64(index) * 1_600, sequence: Int64(index))
            _ = try await store.commitReceivedChunk(fixture.deliver(chunk, to: store))
            chunks.append(chunk)
        }
        try await store.seedCompletionState(chunks: chunks)
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let core = try FrameRange(start: 3_200, count: 50)
        let context = try FrameRange(start: 3_100, count: 200)
        let sources = try [1, 2].map { index in
            let chunk = chunks[index], start = max(chunk.manifest.frames.start, context.start)
            return ArchiveWindowSource(chunkID: chunk.manifest.chunkID, manifestSHA256: chunk.manifestSHA256,
                audioSHA256: chunk.manifest.audioSHA256,
                sourceFrames: try FrameRange(start: start, count: min(chunk.manifest.frames.end, context.end) - start))
        }
        let window = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("cross-chunk-window".utf8)),
            sessionID: fixture.sessionID, epochID: fixture.epochID, analysisAnchor: 1_600,
            coreFrames: core, contextFrames: context, modelCoreFrames: core, modelContextFrames: context,
            sources: sources, configurationFingerprint: fingerprint)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window],
            analyzedCoverage: [FrameRange(start: 0, count: 600), FrameRange(start: 700, count: 7_300)],
            noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        #expect(try await store.completionStates(chunks) == ["failed", "pending", "pending", "superseded", "complete"])

        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: recognition, text: "测试内容", rawResult: Data())
        #expect(try await store.completionStates(chunks) == ["failed", "complete", "complete", "superseded", "complete"])
        #expect(try await store.completionWriteCount(epochID: fixture.epochID, fingerprint: fingerprint) == 0,
            "An unchanged completion pass must not rewrite completed jobs or invalidate the timeline.")

        let gap = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let range = try FrameRange(start: 600, count: 100)
        try await store.commitAnalysisBatch(ticket: gap, windows: [], analyzedCoverage: [range], noSpeechCoverage: [range],
            checkpoint: nil, waitingForMoreAudio: false)
        #expect(try await store.completionStates(chunks) == ["complete", "complete", "complete", "superseded", "complete"])
        #expect(try await store.completionWriteCount(epochID: fixture.epochID, fingerprint: fingerprint) == 0)
    }
}

private extension ArchiveStore {
    func seedCompletionState(chunks: [ManifestEnvelope]) throws {
        try database.execute("UPDATE transcription_jobs SET state='failed' WHERE chunk_id=?", [.text(chunks[0].manifest.chunkID.uuidString)])
        try database.execute("UPDATE transcription_jobs SET state='superseded' WHERE chunk_id=?", [.text(chunks[3].manifest.chunkID.uuidString)])
        // Coverage from another model must not fill the selected configuration's gap.
        try database.execute("INSERT INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind) VALUES(?,?,0,8000,'analyzed')",
            [.text(chunks[0].manifest.epochID.uuidString), .text(ContentHash.sha256(Data("another-model".utf8)))])
    }

    func completionStates(_ chunks: [ManifestEnvelope]) throws -> [String] {
        try chunks.map { chunk in
            try #require(database.rows("SELECT state FROM transcription_jobs WHERE chunk_id=?", [.text(chunk.manifest.chunkID.uuidString)]).first).requireString(0)
        }
    }

    func completionWriteCount(epochID: UUID, fingerprint: String) throws -> Int64 {
        let before = try #require(database.rows("SELECT total_changes()").first).requireInt(0)
        let revision = database.timelineRevision
        try updateCompletedChunks(epochID: epochID, configurationFingerprint: fingerprint)
        #expect(database.timelineRevision == revision)
        return try #require(database.rows("SELECT total_changes()").first).requireInt(0) - before
    }
}
