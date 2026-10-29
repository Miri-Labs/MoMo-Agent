import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

/// Real OS/SQLite failures in disposable storage; these do not fill the host volume.
@Suite(.serialized)
struct ArchiveWriteFailureTests {
    @Test func rejectedAudioMoveKeepsInboxAndWithholdsReceiptUntilRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let item = try fixture.deliver(envelope, to: store)
        let original = item.directoryURL.appendingPathComponent("audio")
        let target = await store.rootURL.appendingPathComponent(store.recordingDirectory(manifest: envelope.manifest))
            .appendingPathComponent("audio").appendingPathComponent(envelope.manifest.chunkID.uuidString + ".wav")
        // Deny unlink/rename at the source directory, after the complete inbox handoff.
        // Reads and preparation of the destination remain possible.
        let permissions = try WriteDeniedDirectory(item.directoryURL)
        defer { permissions.restoreReportingFailure() }
        let failure = await caughtWriteFailure { _ = try await store.commitReceivedChunk(item) }
        #expect(failure?.domain == NSCocoaErrorDomain)
        #expect(failure?.code == CocoaError.fileWriteNoPermission.rawValue)
        #expect(try ContentHash.sha256(fileAt: original) == envelope.manifest.audioSHA256)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try await store.pendingReceipts().isEmpty)
        #expect(try await store.recordings().isEmpty)
        try permissions.restore()

        let reopened = try fixture.store()
        let outcomes = try await reopened.processInbox()
        #expect(outcomes.count == 1)
        guard case .accepted(let receipt) = try #require(outcomes.first).result.get() else {
            Issue.record("Failed inbox item did not recover through processInbox"); return
        }
        #expect(try await reopened.pendingReceipts() == [receipt])
        #expect(try ContentHash.sha256(fileAt: target) == envelope.manifest.audioSHA256)
        guard case .duplicate(let duplicate) = try await reopened.commitReceivedChunk(fixture.deliver(envelope, to: reopened)) else {
            Issue.record("Retransmission was not idempotent"); return
        }
        #expect(duplicate == receipt)
        #expect(try await reopened.recordings().count == 1)
        try await reopened.checkWriteFailureDatabaseIntegrity()
    }

    @Test func sqlitePageLimitRollsBackTranscriptAndAllowsSameAttemptRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimAnalysisJob(configurationHash: "write-failure-model"))
        let database = await store.database
        let originalMaximum = try #require(database.rows("PRAGMA max_page_count").first?.integer(0))
        defer {
            do { try database.execute("PRAGMA max_page_count=\(originalMaximum)") }
            catch { Issue.record("Could not restore disposable SQLite page limit: \(error)") }
        }
        let pageCount = try #require(database.rows("PRAGMA page_count").first?.integer(0))
        let pageSize = try #require(database.rows("PRAGMA page_size").first?.integer(0))
        try database.execute("PRAGMA max_page_count=\(pageCount)")
        #expect(try database.rows("PRAGMA max_page_count").first?.integer(0) == pageCount)
        // About 1 MiB of valid text, much larger than the bounded fixture database.
        // Each individual span remains below the production 64 KiB text limit.
        let text = "容量恢复检查" + String(repeating: "x", count: 60_000)
        let spans = try (0..<16).map { offset in
            TranscriptSpan(chunkID: ticket.chunkID,
                frames: try FrameRange(start: Int64(offset * 100), count: 100), text: text)
        }
        #expect(pageCount * pageSize < Int64(text.utf8.count * spans.count))
        var observed: ArchiveError?
        do { _ = try await store.commitTranscript(ticket: ticket, spans: spans); Issue.record("SQLite quota did not reject growth") }
        catch let error as ArchiveError { observed = error }
        #expect(observed == .database(13), "The original SQLITE_FULL error must survive rollback")
        #expect(try database.rows("SELECT COUNT(*) FROM transcript_versions").first?.integer(0) == 0)
        #expect(try database.rows("SELECT COUNT(*) FROM transcript_search").first?.integer(0) == 0)
        #expect(try database.rows("SELECT transcript_version FROM sessions").first?.integer(0) == 0)
        #expect(try database.rows("SELECT state FROM transcription_jobs").first?.string(0) == "running")
        #expect(try database.rows("SELECT attempt_id FROM transcription_jobs").first?.string(0) == ticket.attemptID.uuidString)
        #expect(try ContentHash.sha256(fileAt: ticket.audioURL) == envelope.manifest.audioSHA256)
        #expect(try await store.pendingReceipts().count == 1)
        try await store.checkWriteFailureDatabaseIntegrity()
        try database.execute("PRAGMA max_page_count=\(originalMaximum)")

        // No recovery blanket reset: a rolled-back transaction leaves this attempt current.
        let document = try await store.commitTranscript(ticket: ticket, spans: spans)
        #expect(document.version == 1 && document.spans == spans)
        #expect(try await store.searchTranscripts(query: "容量恢复检查").count == 16)
        #expect(try database.rows("SELECT COUNT(*) FROM transcript_versions").first?.integer(0) == 1)
        #expect(try database.rows("SELECT state FROM transcription_jobs").first?.string(0) == "complete")
        await #expect(throws: ArchiveError.staleAttempt) { _ = try await store.commitTranscript(ticket: ticket, spans: spans) }
        let reopened = try fixture.store()
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans == spans)
        try await reopened.checkWriteFailureDatabaseIntegrity()
    }

    @Test func deniedTranscriptProjectionKeepsCommittedTextAndRecoversNormally() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        // Publish just the recording manifest so the denied operation below is the
        // actual transcript atomic write, rather than an earlier directory/manifest write.
        try await store.projectRecordingManifest(sessionID: fixture.sessionID)
        let directory = try await store.transcriptDirectory(sessionID: fixture.sessionID)
        let permissions = try WriteDeniedDirectory(directory)
        defer { permissions.restoreReportingFailure() }
        let failure = await caughtWriteFailure { try await store.projectPendingDocuments() }
        #expect(failure?.domain == NSCocoaErrorDomain)
        #expect(failure?.code == CocoaError.fileWriteNoPermission.rawValue)
        let database = await store.database
        let row = try #require(database.rows("SELECT transcript_version,projection_version,projection_blocked FROM sessions").first)
        #expect(row.integer(0) == document.version && row.integer(1) == 0 && row.integer(2) == 1)
        let persisted = try #require(database.rows("SELECT document FROM transcript_versions").first?.data(0))
        #expect(try persisted == WireJSON.encode(document))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.json").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("transcript.md").path))
        await #expect(throws: ArchiveError.projectionConflict) { _ = try await store.readTranscript(sessionID: fixture.sessionID) }
        try permissions.restore()

        let reopened = try fixture.store()
        let reconciliation = try #require(await reopened.reconcileDocumentFiles().first)
        #expect(reconciliation.issue == nil && !reconciliation.didRevise)
        #expect(try reconciliation.result.get() == document.version)
        try await reopened.projectPendingDocuments()
        let json = try await reopened.transcriptFileURL(sessionID: fixture.sessionID, markdown: false)
        let markdown = try await reopened.transcriptFileURL(sessionID: fixture.sessionID)
        #expect(try Data(contentsOf: json) == WireJSON.encode(document))
        #expect(try String(contentsOf: markdown, encoding: .utf8).contains(document.spans[0].text))
        #expect(try await WireJSON.encode(reopened.readTranscript(sessionID: fixture.sessionID)) == WireJSON.encode(document))
        try await reopened.projectPendingDocuments()
        #expect(try database.rows("SELECT COUNT(*) FROM transcript_versions").first?.integer(0) == 1)
        try await reopened.checkWriteFailureDatabaseIntegrity()
    }
}

private final class WriteDeniedDirectory {
    let url: URL
    let original: NSNumber
    private var restored = false
    init(_ url: URL) throws {
        self.url = url
        original = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: url.path)
    }
    func restore() throws {
        guard !restored else { return }
        try FileManager.default.setAttributes([.posixPermissions: original], ofItemAtPath: url.path)
        restored = true
    }
    func restoreReportingFailure() { do { try restore() } catch { Issue.record("Could not restore fixture permissions: \(error)") } }
}

private func caughtWriteFailure(_ operation: () async throws -> Void) async -> NSError? {
    do { try await operation(); Issue.record("Expected a real filesystem write failure"); return nil }
    catch { return error as NSError }
}

private extension ArchiveStore {
    func checkWriteFailureDatabaseIntegrity() throws {
        #expect(try database.rows("PRAGMA integrity_check").first?.string(0) == "ok")
        #expect(try database.rows("PRAGMA foreign_key_check").isEmpty)
    }
}
