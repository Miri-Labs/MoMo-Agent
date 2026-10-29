import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct RecordingFileRecoveryTests {
    @Test func uniqueMovedDirectoryReassociatesEvenAfterReadsWereBlocked() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let old = try await store.transcriptFileURL(sessionID: fixture.sessionID)
        let moved = try move(old.deletingLastPathComponent(), inside: store.rootURL, name: "renamed/nested/我的资料")
        await #expect(throws: ArchiveError.projectionConflict) { try await store.transcriptFileURL(sessionID: fixture.sessionID) }
        let query = try #require(await store.recordingFileIssues().first)
        #expect(query.kind == .missingDirectory)
        #expect(query.candidateDirectories.count == 1)
        #expect(query.availableActions.isEmpty)
        #expect(try await store.transcriptDirectory(sessionID: fixture.sessionID).path == old.deletingLastPathComponent().path)
        let results = try await store.reconcileDocumentFiles()
        #expect(results.count == 1)
        #expect(results[0].issue == nil)
        #expect(!results[0].didRevise)
        #expect(try results[0].result.get() == original.version)
        #expect(try await store.transcriptFileURL(sessionID: fixture.sessionID).deletingLastPathComponent().path == moved.path)
        try await store.validateSources([original.source(for: original.spans[0])])
        let reopened = try fixture.store()
        #expect(try await reopened.recordingFileIssues().isEmpty)
        let lease = try await reopened.acquireAudioLease(chunkID: original.spans[0].chunkID)
        #expect(lease.audioURL.path.hasPrefix(moved.path + "/audio/"))
        #expect(try Data(contentsOf: lease.audioURL) == fixture.audio)
        await reopened.releaseAudioLease(id: lease.id)
    }

    @Test(arguments: [false, true]) func expiredAudioDoesNotOwnDocumentLocation(expireAll: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try fixture.envelope(), second = try fixture.envelope(startFrame: 1600, sequence: 1)
        for envelope in [first, second] {
            guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) else { Issue.record("Expected received chunk"); return }
            try await store.applyReceipt(ReceiptApplied(receipt: receipt))
            let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
            _ = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
        }
        try await store.projectPendingDocuments()
        let original = try await store.readTranscript(sessionID: fixture.sessionID)
        let old = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let expired = try await store.expireAudio(olderThan: Date().addingTimeInterval(60), replayFloors: [fixture.epochID: expireAll ? 3200 : 1600])
        #expect(expired.count == (expireAll ? 2 : 1))
        let moved = try move(old, inside: store.rootURL, name: "已归档/移动")
        let reopened = try fixture.store()
        let results = try await reopened.reconcileDocumentFiles()
        #expect(results.first?.issue == nil)
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
        #expect(try await reopened.transcriptDirectory(sessionID: fixture.sessionID).path == moved.path)
        #expect(try await reopened.recordings().first?.audioState == (expireAll ? .expired : .partiallyExpired))
        if !expireAll {
            let lease = try await reopened.acquireAudioLease(chunkID: second.manifest.chunkID)
            #expect(lease.audioURL.path.hasPrefix(moved.path + "/audio/"))
            await reopened.releaseAudioLease(id: lease.id)
        }
        let third = try fixture.envelope(startFrame: 3200, sequence: 2)
        _ = try await reopened.commitReceivedChunk(fixture.deliver(third, to: reopened))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let newest = try await reopened.acquireAudioLease(chunkID: third.manifest.chunkID)
        #expect(newest.audioURL.path.hasPrefix(moved.path + "/audio/"))
        await reopened.releaseAudioLease(id: newest.id)
    }

    @Test(arguments: ["transcript.json", "transcript.md", "manifest.json"]) func missingProjectionNeedsExplicitConfirmation(filename: String) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let removed = directory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: removed)
        let issue = try #require(await store.recordingFileIssues().first)
        #expect(issue.kind == .missingFiles)
        #expect(issue.missingFiles == [filename])
        try await store.projectPendingDocuments()
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        let preview = try await store.recordingRecoveryPreview(issue, choosing: .restoreDatabase)
        #expect(preview.spans == original.spans)
        guard case .restored(let version) = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase) else { Issue.record("Expected restore"); return }
        #expect(version == original.version)
        #expect(try await store.recordingFileIssues().isEmpty)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).generation == original.generation)
        #expect(FileManager.default.fileExists(atPath: removed.path))
    }

    @Test func deletedDirectoryDoesNotReappearFromProjectionOrNewAudio() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        try FileManager.default.removeItem(at: directory)
        let issue = try #require(await store.recordingFileIssues().first)
        #expect(issue.kind == .missingDirectory)
        try await store.projectPendingDocuments()
        let later = try fixture.envelope(startFrame: 1600, sequence: 1)
        let item = try fixture.deliver(later, to: store)
        await #expect(throws: ArchiveError.projectionConflict) { try await store.commitReceivedChunk(item) }
        #expect(FileManager.default.fileExists(atPath: item.directoryURL.path))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        _ = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase)
        #expect(try await store.readTranscript(sessionID: fixture.sessionID).spans == original.spans)
        #expect(try await store.recordings().first?.audioState == .missingUnexpected)
        guard case .accepted = try await store.commitReceivedChunk(item) else { Issue.record("Expected new chunk after explicit recovery"); return }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("audio/\(original.spans[0].chunkID).wav").path))
    }

    @Test func conflictingEditsRejectStaleChoicesAndInvalidateOldSources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let original = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let oldSpan = original.spans[0]
        let agent = UUID()
        try await store.registerAgentSources(agentSessionID: agent, sources: [original.source(for: oldSpan)])
        try writeJSON(original, text: "选择JSON修订。", directory: directory)
        try writeMarkdown(replacing: oldSpan.text, with: "选择Markdown修订。", directory: directory)
        let results = try await store.reconcileDocumentFiles()
        let issue = try #require(results.first?.issue)
        #expect(issue.kind == .conflictingEdits)
        #expect(issue.availableActions.contains(.useJSON) && issue.availableActions.contains(.useMarkdown))
        #expect(try await store.pendingAgentCleanups().contains(agent))
        #expect(try await store.recordingRecoveryPreview(issue, choosing: .useMarkdown).spans.first?.text == "选择Markdown修订。")
        try writeJSON(original, text: "确认窗口打开后又修改。", directory: directory)
        await #expect(throws: ArchiveError.staleSource) { try await store.resolveRecordingFiles(issue, choosing: .useMarkdown) }
        #expect(try WireJSON.decode(TranscriptDocument.self, from: Data(contentsOf: directory.appendingPathComponent("transcript.json"))).spans.first?.text == "确认窗口打开后又修改。")
        let current = try #require(await store.recordingFileIssues().first)
        guard case .revised(let version) = try await store.resolveRecordingFiles(current, choosing: .useMarkdown) else { Issue.record("Expected revision"); return }
        #expect(version == original.version + 1)
        let revised = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(revised.spans.first?.text == "选择Markdown修订。")
        #expect(revised.generation == original.generation + 1)
        await #expect(throws: ArchiveError.staleSource) { try await store.validateSources([original.source(for: oldSpan)]) }
        #expect(try await store.recordingFileIssues().isEmpty)
    }

    @Test func readOnlyIssuesDoNotImportEditsAndBatchFailureDoesNotBlockHealthyRecording() async throws {
        let fixture = try Fixture(), other = try Fixture()
        defer { fixture.remove(); other.remove() }
        let store = try fixture.store()
        let blocked = try await fixture.transcribe(store), healthy = try await other.transcribe(store)
        try await store.projectPendingDocuments()
        let blockedDirectory = try await store.transcriptDirectory(sessionID: blocked.sessionID)
        let healthyDirectory = try await store.transcriptDirectory(sessionID: healthy.sessionID)
        try FileManager.default.removeItem(at: blockedDirectory.appendingPathComponent("transcript.md"))
        try writeJSON(healthy, text: "健康资料仍然导入修订。", directory: healthyDirectory)
        let issues = try await store.recordingFileIssues()
        #expect(issues.map(\.sessionID) == [blocked.sessionID])
        #expect(try await store.readTranscript(sessionID: healthy.sessionID).version == healthy.version)
        let results = try await store.reconcileDocumentFiles()
        #expect(results.first(where: { $0.sessionID == blocked.sessionID })?.issue?.kind == .missingFiles)
        #expect(results.first(where: { $0.sessionID == healthy.sessionID })?.didRevise == true)
        #expect(try await store.readTranscript(sessionID: healthy.sessionID).spans.first?.text == "健康资料仍然导入修订。")
    }

    @Test func ambiguousMovesAndSymbolicLinksAreNotFollowedOrOverwritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let first = try move(directory, inside: store.rootURL, name: "copies/one")
        let second = first.deletingLastPathComponent().appendingPathComponent("two")
        try FileManager.default.copyItem(at: first, to: second)
        let ambiguous = try #require(await store.reconcileDocumentFiles().first?.issue)
        #expect(ambiguous.kind == .ambiguousLocation)
        #expect(ambiguous.candidateDirectories.count == 2)
        #expect(ambiguous.availableActions.isEmpty)
        try FileManager.default.moveItem(at: first, to: directory)
        try FileManager.default.removeItem(at: second)
        let external = fixture.root.appendingPathComponent("outside.md")
        let bytes = Data("外部文件，不得读取或改写。".utf8)
        try bytes.write(to: external)
        let markdown = directory.appendingPathComponent("transcript.md")
        try FileManager.default.removeItem(at: markdown)
        try FileManager.default.createSymbolicLink(at: markdown, withDestinationURL: external)
        let reopened = try fixture.store()
        let unsafe = try #require(await reopened.reconcileDocumentFiles().first?.issue)
        #expect(unsafe.kind == .unsafePath)
        #expect(unsafe.availableActions.isEmpty)
        try await reopened.projectPendingDocuments()
        #expect(try Data(contentsOf: external) == bytes)
        // URL resource values can be cached from before the regular file was replaced by a link.
        let attributes = try FileManager.default.attributesOfItem(atPath: markdown.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func recoveryBeforeTranscriptionAndConfirmedDeletionHaveExplicitOutcomes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        // Sidecars suffice to identify a move before either text projection exists.
        let moved = try move(directory, inside: store.rootURL, name: "未转写/移动")
        #expect(try await store.reconcileDocumentFiles().first?.issue == nil)
        #expect(try await store.transcriptDirectory(sessionID: fixture.sessionID).path == moved.path)
        try FileManager.default.removeItem(at: moved)
        let issue = try #require(await store.recordingFileIssues().first)
        let preview = try await store.recordingRecoveryPreview(issue, choosing: .restoreDatabase)
        #expect(preview.version == 0 && preview.spans.isEmpty)
        guard case .restored(let version) = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase) else { Issue.record("Expected empty restoration"); return }
        #expect(version == 0)
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("manifest.json").path))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("transcript.json").path))
        try FileManager.default.removeItem(at: moved)
        let deletionIssue = try #require(await store.recordingFileIssues().first)
        guard case .deleted(let deletion) = try await store.resolveRecordingFiles(deletionIssue, choosing: .deleteRecording) else { Issue.record("Expected deletion"); return }
        #expect(deletion.sessionID == fixture.sessionID)
        #expect(try await store.recordings().isEmpty)
        let reopened = try fixture.store()
        guard case .deleted = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened)) else { Issue.record("Deletion must reject late delivery"); return }
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func schemaFiveBackfillsStableDirectoryOwnership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await fixture.transcribe(store)
        try await store.projectPendingDocuments()
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        try await store.makeSchemaFiveFixture()
        let reopened = try fixture.store()
        #expect(try await reopened.transcriptDirectory(sessionID: fixture.sessionID).path == directory.path)
        #expect(try await reopened.recordingFileIssues().isEmpty)
        _ = try move(directory, inside: reopened.rootURL, name: "迁移后/移动")
        #expect(try await reopened.reconcileDocumentFiles().first?.issue == nil)
    }

    private func move(_ directory: URL, inside root: URL, name: String) throws -> URL {
        let destination = root.appendingPathComponent("Documents/recordings/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory, to: destination)
        return destination
    }

    private func writeJSON(_ original: TranscriptDocument, text: String, directory: URL) throws {
        let span = original.spans[0]
        let revised = TranscriptDocument(sessionID: original.sessionID, version: original.version, generation: original.generation,
            spans: [TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: text, speaker: span.speaker, sourceRanges: span.sourceRanges)], updatedAt: original.updatedAt)
        try WireJSON.encode(revised).write(to: directory.appendingPathComponent("transcript.json"))
    }

    private func writeMarkdown(replacing old: String, with text: String, directory: URL) throws {
        let url = directory.appendingPathComponent("transcript.md")
        let markdown = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: old, with: text)
        try Data(markdown.utf8).write(to: url)
    }
}

extension ArchiveStore {
    func makeSchemaFiveFixture() throws {
        try database.transaction {
            try restoreLegacyHistoryForTests()
            try database.execute("ALTER TABLE sessions DROP COLUMN transcript_preview")
            try database.execute("DROP TABLE analysis_range_inputs")
            try database.execute("DROP TABLE processing_turns")
            try database.execute("DROP INDEX analysis_windows_pending")
            try database.execute("DROP INDEX chunks_epoch_frames")
            try database.execute("DROP INDEX chunks_epoch_ends")
            try database.execute("ALTER TABLE analysis_epochs DROP COLUMN has_pending")
            try database.execute("DROP TABLE processing_failures")
            try database.execute("DROP TABLE reconcile_requests")
            try database.execute("DROP TABLE watch_status")
            try database.execute("DROP TABLE transcription_batch_executions")
            try database.execute("DROP TABLE transcription_batch_ranges")
            try database.execute("DROP TABLE transcription_batch_windows")
            try database.execute("DROP TABLE transcription_batches")
            try database.execute("ALTER TABLE plans DROP COLUMN projection_hash")
            try database.execute("ALTER TABLE plans DROP COLUMN revision")
            try database.execute("DROP INDEX session_document_directory")
            try database.execute("ALTER TABLE sessions DROP COLUMN document_directory")
            try database.execute("ALTER TABLE sessions DROP COLUMN manifest_projected")
            try database.execute("PRAGMA user_version=5")
        }
    }
}
