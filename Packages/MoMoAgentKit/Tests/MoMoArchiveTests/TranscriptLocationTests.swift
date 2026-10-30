import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TranscriptLocationTests {
    @Test func recordingAudioPagesPlaySilenceInCaptureOrderAndFreezeReceivedChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [second, first] {
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        let fingerprint = ContentHash.sha256(Data("silence-playback".utf8))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3200)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let analyzed = try FrameRange(start: 0, count: 3200)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [], analyzedCoverage: [analyzed],
            noSpeechCoverage: [analyzed], checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID,
                epochID: fixture.epochID, sourceFrame: 3200, configurationFingerprint: fingerprint), waitingForMoreAudio: false)
        #expect(try await store.recordings().first?.transcriptionState == .noSpeech)
        await #expect(throws: ArchiveError.missingTranscript(fixture.sessionID)) { try await store.readTranscript(sessionID: fixture.sessionID) }
        let page1 = try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0, limit: 1)
        #expect(page1.parts.map(\.lease.chunkID) == [first.manifest.chunkID])
        #expect(page1.parts.first?.frames == first.manifest.frames)
        let cursor = try #require(page1.nextCursor)
        await store.releaseAudioLease(id: try #require(page1.parts.first).lease.id)

        // A newly received epoch belongs to the next play, not an already running snapshot.
        let later = try ManifestEnvelope(manifest: ChunkManifest(sessionID: fixture.sessionID, epochID: UUID(),
            chunkID: UUID(), sourceDeviceID: fixture.deviceID, sourceBuild: "tests", sequence: 0,
            frames: FrameRange(start: 0, count: 1600), timebaseHz: 16000,
            wallClockAnchor: first.manifest.wallClockAnchor.addingTimeInterval(1), timezoneOffset: 28800,
            codec: .pcmInt16, sampleRate: 16000, channels: 1, decodedFrameCount: 1600,
            byteCount: Int64(fixture.audio.count), audioSHA256: ContentHash.sha256(fixture.audio), sourceKind: .fixture))
        _ = try await store.commitReceivedChunk(fixture.deliver(later, to: store))
        let page2 = try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0, cursor: cursor, limit: 1)
        #expect(page2.parts.map(\.lease.chunkID) == [second.manifest.chunkID])
        #expect(page2.nextCursor == nil)
        await store.releaseAudioLease(id: try #require(page2.parts.first).lease.id)
        let all = try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0)
        #expect(all.parts.map(\.lease.chunkID) == [first.manifest.chunkID, second.manifest.chunkID, later.manifest.chunkID])
        for part in all.parts { await store.releaseAudioLease(id: part.lease.id) }
    }

    @Test func recordingPlaybackRejectsStaleGenerationAndDeletionWhileKeepingActiveLease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: document.version, spans: [])
        await #expect(throws: ArchiveError.staleSource) {
            try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: document.generation)
        }
        let current = try await store.readTranscript(sessionID: fixture.sessionID)
        let page = try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: current.generation)
        let part = try #require(page.parts.first)
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(FileManager.default.fileExists(atPath: part.lease.audioURL.path))
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: current.generation)
        }
        await store.releaseAudioLease(id: part.lease.id)
        try await store.cleanDeletedFiles()
        #expect(!FileManager.default.fileExists(atPath: part.lease.audioURL.path))
    }

    @Test func recordingPlaybackRejectsMissingAudioAndReleasesPartiallyAcquiredPage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] { _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) }
        let original = try await store.acquireAudioLease(chunkID: first.manifest.chunkID)
        await store.releaseAudioLease(id: original.id)
        let missing = try await store.acquireAudioLease(chunkID: second.manifest.chunkID)
        await store.releaseAudioLease(id: missing.id)
        try FileManager.default.removeItem(at: missing.audioURL)
        await #expect(throws: ArchiveError.missingRecording(second.manifest.chunkID)) {
            try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0)
        }
        #expect(try await store.recordings().first?.audioState == .missingUnexpected)
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(!FileManager.default.fileExists(atPath: original.audioURL.path), "Failed acquisition must not leak the first file's lease.")
    }

    @Test func recordingPlaybackRejectsExpiredAudioAndForeignCursors() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] {
            guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
                Issue.record("Expected receipt"); return
            }
            try await store.applyReceipt(ReceiptApplied(receipt: receipt))
            let ticket = try #require(await store.claimAnalysisJob(configurationHash: "playback-expiry"))
            _ = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        }
        let page = try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0, limit: 1)
        let cursor = try #require(page.nextCursor)
        await store.releaseAudioLease(id: try #require(page.parts.first).lease.id)
        let other = try ArchiveStore(rootURL: fixture.root.appendingPathComponent("OtherLibrary"), receiverDeviceID: fixture.deviceID)
        _ = try await other.commitReceivedChunk(fixture.deliver(first, to: other))
        await #expect(throws: ArchiveError.invalidQuery) {
            try await other.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0, cursor: cursor)
        }
        await #expect(throws: ArchiveError.invalidQuery) {
            try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0, limit: 33)
        }
        _ = try await store.applyRetention(now: first.manifest.sealedAt.addingTimeInterval(8 * 86_400),
                                           replayFloors: [fixture.epochID: 3200])
        await #expect(throws: ArchiveError.missingRecording(second.manifest.chunkID)) {
            try await store.acquireRecordingAudioPage(sessionID: fixture.sessionID, expectedGeneration: 0, cursor: cursor)
        }
    }

    @Test func locationsUseEpochClockAndKeepTextWhenAudioExpires() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        let second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] {
            guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else {
                Issue.record("Expected receipt"); return
            }
            try await store.applyReceipt(ReceiptApplied(receipt: receipt))
        }
        for _ in 0..<2 {
            let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
            _ = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        }
        let document = try await store.readTranscript(sessionID: fixture.sessionID)
        let span = try #require(document.spans.first { $0.chunkID == second.manifest.chunkID })
        let location = try #require(await store.transcriptLocations(document: document)[span.id])
        #expect(abs(location.recordedAt.timeIntervalSince(second.manifest.wallClockAnchor) - 0.1) < 0.000001)
        #expect(location.audioAvailable)
        _ = try await store.applyRetention(now: second.manifest.sealedAt.addingTimeInterval(8 * 86_400),
                                           replayFloors: [fixture.epochID: 3200])
        let expired = try #require(await store.transcriptLocations(document: document)[span.id])
        #expect(!expired.audioAvailable)
        #expect(expired.recordedAt == location.recordedAt)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans == document.spans)
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: document.version, spans: document.spans)
        await #expect(throws: ArchiveError.staleSource) { try await store.transcriptLocations(document: document) }
    }
}
