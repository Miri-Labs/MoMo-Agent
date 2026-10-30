import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct PlaybackTimelineTests {
    @Test func previewStampChecksOnlyTheRequestedPartAndKeepsOriginalIdentityBarriers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        for index in 0..<3 {
            _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(
                startFrame: Int64(index * 1600), sequence: Int64(index)), to: store))
        }
        let timeline = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: 0)
        let stamps = try await store.playbackPreviewFileStamps(in: timeline)
        let part = timeline.parts[1]
        let before = await store.playbackPreviewStampReadCount
        #expect(try await store.playbackPreviewFileStamp(for: part, in: timeline) == stamps[part.manifest.chunkID])
        #expect(await store.playbackPreviewStampReadCount == before + 1)
        let other = try await store.waveformPreparationEntry(chunkID: timeline.parts[0].manifest.chunkID)
        let otherTimeline = try #require(other).timeline
        await #expect(throws: ArchiveError.staleSource) {
            _ = try await store.playbackPreviewFileStamp(for: part, in: otherTimeline)
        }
        let leased = try await store.acquirePlaybackPart(part, in: timeline)
        let audioURL = leased.lease.audioURL
        await store.releaseAudioLease(id: leased.lease.id)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: audioURL.path)
        #expect(try await store.playbackPreviewFileStamp(for: part, in: timeline) != stamps[part.manifest.chunkID])
        let manifestURL = audioURL.appendingPathExtension("manifest.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        try Data("damaged manifest".utf8).write(to: manifestURL)
        await #expect(throws: ArchiveError.missingRecording(part.manifest.chunkID)) {
            _ = try await store.playbackPreviewFileStamp(for: part, in: timeline)
        }
        try originalManifest.write(to: manifestURL)
        try FileManager.default.removeItem(at: audioURL)
        await #expect(throws: ArchiveError.missingRecording(part.manifest.chunkID)) {
            _ = try await store.playbackPreviewFileStamp(for: part, in: timeline)
        }
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            _ = try await store.playbackPreviewFileStamp(for: timeline.parts[0], in: timeline)
        }
    }

    @Test func cancelledPreviewScanDoesNotReadFilesOrPublishMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
        let timeline = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: 0)
        let scan = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await store.playbackPreviewFileStamps(in: timeline)
        }
        scan.cancel()
        await #expect(throws: CancellationError.self) { _ = try await scan.value }
        #expect(await store.playbackPreviewStampReadCount == 0)
    }

    @Test func selectedWindowClipsOnlyOverlappingChunksAndKeepsMissingAudioAndGenerationChecks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        for index in 0..<3 {
            let envelope = index == 0 ? first : try fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index))
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        let source = TimelineAudioSource(sessionID: fixture.sessionID, generation: 0, epochID: fixture.epochID,
            frames: try FrameRange(start: 800, count: 1600), timebaseHz: 16000, wallClockAnchor: first.manifest.wallClockAnchor)
        let timeline = try #require(await store.playbackTimelines(sources: [source]).first)
        #expect(timeline.parts.map(\.frames) == [try FrameRange(start: 800, count: 800), try FrameRange(start: 1600, count: 800)])
        let part = try await store.acquirePlaybackPart(timeline.parts[1], in: timeline)
        await store.releaseAudioLease(id: part.lease.id)
        try FileManager.default.removeItem(at: part.lease.audioURL)
        let missing = try #require(await store.playbackTimelines(sources: [source]).first)
        #expect(missing.parts.map(\.audioAvailable) == [true, false])
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) { _ = try await store.playbackTimelines(sources: [source]) }
    }

    @Test func activeClockValidationKeepsAppendRevisionDeletionAndFilesBarriers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        let source = original.source(for: original.spans[0])
        let frozen = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: source.generation, source: source)
        let later = try fixture.envelope(startFrame: 1_600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(later, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
        let appended = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        #expect(appended.version > original.version)
        try await store.validateActivePlaybackTimeline(frozen)
        try await store.validatePlaybackTimeline(frozen)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.md"))
        _ = try await store.reconcileDocumentFiles()
        #expect(try await store.recordingSummary(sessionID: fixture.sessionID).generation == source.generation)
        await #expect(throws: ArchiveError.projectionConflict) { try await store.validateActivePlaybackTimeline(frozen) }
        await #expect(throws: ArchiveError.projectionConflict) { try await store.validatePlaybackTimeline(frozen) }
        let issue = try #require(await store.recordingFileIssues().first)
        _ = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase)
        try await store.validateActivePlaybackTimeline(frozen)
        let revised = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: appended.version, spans: [])
        await #expect(throws: ArchiveError.staleSource) { try await store.validateActivePlaybackTimeline(frozen) }
        let current = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: revised.generation)
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) { try await store.validateActivePlaybackTimeline(current) }
    }

    @Test func frozenMetadataDoesNotPinAudioAndNewReceiptsDoNotChangeItsRange() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(first, to: store))
        let frozen = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: 0)
        #expect(frozen.parts.count == 1)
        let next = try fixture.envelope(startFrame: 3_200, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(next, to: store))
        try await store.validatePlaybackTimeline(frozen)
        #expect(frozen.parts.count == 1)
        let updated = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: 0)
        #expect(updated.parts.map(\.frames.start) == [0, 3_200])
        let part = try await store.acquirePlaybackPart(frozen.parts[0], in: frozen)
        await store.releaseAudioLease(id: part.lease.id)
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(!FileManager.default.fileExists(atPath: part.lease.audioURL.path))
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await store.acquirePlaybackPart(frozen.parts[0], in: frozen)
        }
    }

    @Test func missingAudioRemainsAnExplicitDescriptorAndRevisionInvalidatesOldTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        let source = document.source(for: document.spans[0])
        let frozen = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: source.generation, source: source)
        let lease = try await store.acquirePlaybackPart(frozen.parts[0], in: frozen)
        await store.releaseAudioLease(id: lease.lease.id)
        try FileManager.default.removeItem(at: lease.lease.audioURL)
        let missing = try await store.playbackTimeline(sessionID: fixture.sessionID, expectedGeneration: source.generation)
        #expect(missing.parts.count == 1)
        #expect(!missing.parts[0].audioAvailable)
        await #expect(throws: ArchiveError.missingRecording(lease.lease.chunkID)) {
            try await store.acquirePlaybackPart(frozen.parts[0], in: frozen)
        }
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: document.version, spans: [])
        await #expect(throws: ArchiveError.staleSource) { try await store.validatePlaybackTimeline(frozen) }
    }
}
