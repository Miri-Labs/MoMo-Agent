import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct RecordingReadLatencyTests {
    @Test func repeatedLongSnapshotReadsDecodeOnceAndPreviewDoesNotDecode() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "cached-read"))
        let spans = (0..<4_000).map {
            TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "第\($0)段，" + String(repeating: "文字", count: 40))
        }
        let original = try await store.commitTranscript(ticket: ticket, spans: spans)
        let before = await store.transcriptReadDecodeCount
        #expect(try await store.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: original.version,
            expectedGeneration: original.generation) == String(spans[0].text.prefix(160)))
        #expect(await store.transcriptReadDecodeCount == before)
        _ = try await store.transcriptSnapshot(sessionID: fixture.sessionID)
        let cold = await store.transcriptReadDecodeCount
        let start = ContinuousClock.now
        for _ in 0..<12 {
            let snapshot = try await store.transcriptSnapshot(sessionID: fixture.sessionID)
            #expect(snapshot.document.spans.count == spans.count)
            #expect(snapshot.locations.count == spans.count)
        }
        print("12 warm snapshots, 4000 spans: \(start.duration(to: .now))")
        #expect(cold == before + 1)
        #expect(await store.transcriptReadDecodeCount == cold)
        let revised = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: original.version, spans: [])
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).version == revised.version)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans.isEmpty)
        #expect(try await store.transcriptPreview(sessionID: fixture.sessionID, expectedVersion: original.version,
            expectedGeneration: original.generation) == nil)
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.sessionDeleted(fixture.sessionID)) {
            try await store.readTranscript(sessionID: fixture.sessionID)
        }
    }

    @Test func externalSQLiteChangesAndRollbackDoNotReuseStaleText() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        _ = try await store.readTranscript(sessionID: fixture.sessionID)
        let old = try #require(original.spans.first)
        let edited = TranscriptSpan(id: old.id, chunkID: old.chunkID, frames: old.frames, text: "事务中的临时文字")
        let temporary = TranscriptDocument(sessionID: original.sessionID, version: original.version,
            generation: original.generation, spans: [edited], updatedAt: original.updatedAt)
        #expect(try await store.readAndRollbackForCacheTest(temporary).spans[0].text == edited.text)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
        let database = try ArchiveDatabase(url: store.rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/archive.sqlite"))
        try database.execute("UPDATE transcript_versions SET document=? WHERE session_id=? AND version=?",
            [.blob(try WireJSON.encode(temporary)), .text(original.sessionID.uuidString), .integer(original.version)])
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans[0].text == edited.text)
    }

    @Test func longUnchangedProjectionsRemainReadableWithoutImportingEdits() async throws {
        for count in [1_000, 4_000] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let store = try fixture.store()
            _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
            let ticket = try #require(await store.claimAnalysisJob(configurationHash: "read-latency"))
            let spans = (0..<count).map {
                TranscriptSpan(chunkID: ticket.chunkID, frames: ticket.manifest.frames, text: "第\($0)段录音，保留原有正文与来源。")
            }
            let original = try await store.commitTranscript(ticket: ticket, spans: spans)
            try await store.projectPendingDocuments()
            let clock = ContinuousClock(), start = clock.now
            #expect(try await store.recordingFileIssues().isEmpty)
            let elapsed = start.duration(to: clock.now)
            print("Recording inspection: \(count) spans, \(elapsed)")
            let reconciled = try await store.reconcileDocumentFiles()
            #expect(reconciled.count == 1 && reconciled[0].issue == nil && !reconciled[0].didRevise)
            let loaded = try await store.readTranscript(sessionID: fixture.sessionID)
            #expect(loaded.version == original.version && loaded.spans == original.spans)

            let markdown = try await store.transcriptFileURL(sessionID: fixture.sessionID)
            let last = try #require(original.spans.last)
            let edited = try String(contentsOf: markdown, encoding: .utf8).replacingOccurrences(of: last.text, with: "长录音末尾的修订。")
            try Data(edited.utf8).write(to: markdown, options: .atomic)
            let revision = try await store.reconcileDocumentFiles()
            #expect(revision.count == 1 && revision[0].didRevise && revision[0].issue == nil)
            let updated = try await store.readTranscript(sessionID: fixture.sessionID)
            #expect(updated.spans.count == count && updated.spans.last?.text == "长录音末尾的修订。")
            #expect(updated.spans.last?.sourceRanges == last.sourceRanges)
        }
    }

    @Test func openingOneRecordingDoesNotInspectUnrelatedFiles() async throws {
        let selected = try Fixture(), other = try Fixture()
        defer { selected.remove(); other.remove() }
        let store = try selected.store()
        _ = try await selected.transcribe(store)
        _ = try await other.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: other.sessionID)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.md"))
        #expect(try await store.recordingFileIssues(sessionID: selected.sessionID).isEmpty)
        let scoped = try await store.recordingFileIssues(sessionID: other.sessionID)
        #expect(scoped.count == 1 && scoped[0].sessionID == other.sessionID && scoped[0].kind == .missingFiles)
        #expect(try await store.recordingFileIssues() == scoped)
        _ = try await store.deleteSession(id: other.sessionID)
        #expect(try await store.recordingFileIssues(sessionID: other.sessionID).isEmpty)
    }

    @Test(arguments: ["transcript.json", "transcript.md"])
    func indexedValidationStillRejectsChangedSourceFrames(filename: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let old = try #require(original.spans.first)
        let file = try await store.transcriptDirectory(sessionID: fixture.sessionID).appendingPathComponent(filename)
        if filename == "transcript.json" {
            let span = TranscriptSpan(id: old.id, chunkID: old.chunkID, frames: try FrameRange(start: 0, count: 1599),
                text: old.text, speaker: old.speaker, sourceRanges: old.sourceRanges)
            let invalid = TranscriptDocument(sessionID: original.sessionID, version: original.version,
                generation: original.generation, spans: [span], updatedAt: original.updatedAt)
            try WireJSON.encode(invalid).write(to: file, options: .atomic)
        } else {
            let invalid = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "count=1600", with: "count=1599")
            try Data(invalid.utf8).write(to: file, options: .atomic)
        }
        let issue = try #require(await store.recordingFileIssues(sessionID: fixture.sessionID).first)
        #expect(issue.kind == .invalidEdit)
        #expect(!(filename == "transcript.json" ? issue.availableActions.contains(.useJSON) : issue.availableActions.contains(.useMarkdown)))
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
    }
}

private enum CacheTestRollback: Error { case requested }
private extension ArchiveStore {
    func readAndRollbackForCacheTest(_ document: TranscriptDocument) throws -> TranscriptDocument {
        var observed: TranscriptDocument?
        do {
            try database.transaction {
                try database.execute("UPDATE transcript_versions SET document=? WHERE session_id=? AND version=?",
                    [.blob(try WireJSON.encode(document)), .text(document.sessionID.uuidString), .integer(document.version)])
                observed = try readTranscript(sessionID: document.sessionID)
                throw CacheTestRollback.requested
            }
        } catch CacheTestRollback.requested { }
        return try #require(observed)
    }
}
