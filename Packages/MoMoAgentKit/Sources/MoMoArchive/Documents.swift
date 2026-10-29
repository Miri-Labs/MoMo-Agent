import Foundation
import MoMoContracts

extension ArchiveStore {
    public func projectPendingDocuments(sessionID: UUID? = nil, includeUnchanged: Bool = true) async throws {
        var firstFailure: (any Error)?
        let condition = sessionID == nil ? "" : " AND id=?"
        let values = sessionID.map { [SQLValue.text($0.uuidString)] } ?? []
        let pending = includeUnchanged ? "" : " AND (transcript_version>projection_version OR manifest_projected=0 OR EXISTS (SELECT 1 FROM metadata m WHERE m.key='recording_projection_pending/'||sessions.id))"
        let ids = try database.rows("SELECT id FROM sessions WHERE deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL\(pending)\(condition)", values).map { try $0.requireUUID(0) }
        for id in ids {
            try Task.checkCancellation()
            guard let row = try database.rows("SELECT id,transcript_version,projection_version FROM sessions WHERE id=? AND deleted=0 AND projection_blocked=0 AND document_directory IS NOT NULL", [.text(id.uuidString)]).first else { continue }
            do {
                let inspection = try inspectRecordingFiles(sessionID: id, allowRelocation: false)
                // Only Runtime reconciliation imports edits and reports revisions to its consumers.
                guard inspection.issue == nil, inspection.automaticEdit == nil else {
                    try blockProjection(sessionID: id)
                    await Task.yield()
                    continue
                }
                try projectRecordingManifest(sessionID: id)
                if try row.requireInt(1) > row.requireInt(2) { try projectTranscript(sessionID: id) }
                try database.execute("DELETE FROM metadata WHERE key=?", [.text("recording_projection_pending/" + id.uuidString)])
            } catch {
                try blockProjection(sessionID: id)
                if firstFailure == nil { firstFailure = error }
            }
            await Task.yield()
        }
        if sessionID == nil {
            for row in try database.rows("SELECT document FROM plans WHERE state='pending'") {
                do { try projectPlan(try WireJSON.decode(PlanDocument.self, from: row.requireData(0))) }
                catch { if firstFailure == nil { firstFailure = error } }
            }
            do { try cleanDeletedPlanFiles() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }

    public func transcriptFileURL(sessionID: UUID, markdown: Bool = true) throws -> URL {
        let document = try readTranscript(sessionID: sessionID)
        guard let row = try database.rows("SELECT projection_version,projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              row.integer(0) == document.version, row.integer(1) == 0 else { throw ArchiveError.projectionPending }
        let directory = try transcriptDirectory(sessionID: sessionID)
        let url = directory.appendingPathComponent(markdown ? "transcript.md" : "transcript.json")
        try validateRecordingPath(url)
        let expected = try markdown ? Data(transcriptMarkdown(document).utf8) : WireJSON.encode(document)
        guard files.fileExists(atPath: url.path), try Data(contentsOf: url) == expected else {
            try blockProjection(sessionID: sessionID)
            throw ArchiveError.projectionConflict
        }
        return url
    }

    /// Accept an explicitly reconciled edit only against the version shown to its author.
    public func reconcileTranscriptFile(sessionID: UUID, fileURL: URL) throws -> TranscriptDocument {
        let directory = try transcriptDirectory(sessionID: sessionID)
        guard fileURL.standardizedFileURL == directory.appendingPathComponent("transcript.json").standardizedFileURL else { throw ArchiveError.invalidQuery }
        try validateRecordingPath(fileURL)
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalidTranscript }
        let edited = try WireJSON.decode(TranscriptDocument.self, from: data)
        guard edited.sessionID == sessionID else { throw ArchiveError.invalidTranscript }
        let document = try reviseTranscript(sessionID: sessionID, expectedVersion: edited.version, spans: edited.spans)
        // The edit has become a new authoritative version; replace both projections together with their version gate closed.
        try database.execute("UPDATE sessions SET projection_version=0,projection_blocked=0 WHERE id=?", [.text(sessionID.uuidString)])
        try projectTranscript(sessionID: sessionID)
        return document
    }

    func projectRecordingManifest(sessionID: UUID) throws {
        let chunks = try database.rows("SELECT manifest FROM chunks WHERE session_id=? ORDER BY rowid", [.text(sessionID.uuidString)]).map {
            try WireJSON.decode(ChunkManifest.self, from: $0.requireData(0))
        }
        guard !chunks.isEmpty else { return }
        let data = try WireJSON.encode(RecordingManifest(sessionID: sessionID, chunks: chunks))
        let url = try transcriptDirectory(sessionID: sessionID).appendingPathComponent("manifest.json")
        try validateRecordingPath(url)
        if !files.fileExists(atPath: url.path),
           try database.rows("SELECT manifest_projected FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first?.integer(0) == 1 {
            try blockProjection(sessionID: sessionID)
            throw ArchiveError.projectionConflict
        }
        if files.fileExists(atPath: url.path), try Data(contentsOf: url) == data {
            try database.execute("UPDATE sessions SET manifest_projected=1 WHERE id=? AND manifest_projected!=1", [.text(sessionID.uuidString)])
            return
        }
        try ArchiveFilePolicy.write(data, to: url)
        try database.execute("UPDATE sessions SET manifest_projected=1 WHERE id=?", [.text(sessionID.uuidString)])
    }

    func projectTranscript(sessionID: UUID) throws {
        let document = try readTranscript(sessionID: sessionID)
        guard let row = try database.rows("SELECT projection_version,projection_blocked FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              row.integer(1) == 0 else { throw ArchiveError.projectionConflict }
        let version = try row.requireInt(0)
        let directory = try transcriptDirectory(sessionID: sessionID)
        let jsonURL = directory.appendingPathComponent("transcript.json")
        let markdownURL = directory.appendingPathComponent("transcript.md")
        try validateRecordingPath(jsonURL)
        try validateRecordingPath(markdownURL)
        let json = try WireJSON.encode(document)
        let markdown = Data(transcriptMarkdown(document).utf8)
        if version > 0 {
            guard let previous = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=?", [.text(sessionID.uuidString), .integer(version)]).first else { throw ArchiveError.database(11) }
            let old = try decodeStoredTranscript(previous.requireData(0))
            let oldJSON = try WireJSON.encode(old), oldMarkdown = Data(transcriptMarkdown(old).utf8)
            for (url, before, after) in [(jsonURL, oldJSON, json), (markdownURL, oldMarkdown, markdown)] {
                guard files.fileExists(atPath: url.path) else { try blockProjection(sessionID: sessionID); throw ArchiveError.projectionConflict }
                let existing = try Data(contentsOf: url)
                guard existing == before || existing == after else { try blockProjection(sessionID: sessionID); throw ArchiveError.projectionConflict }
            }
        }
        try validateRecordingPath(directory)
        guard files.fileExists(atPath: directory.path) else { try blockProjection(sessionID: sessionID); throw ArchiveError.projectionConflict }
        try ArchiveFilePolicy.write(json, to: jsonURL)
        try ArchiveFilePolicy.write(markdown, to: markdownURL)
        try database.execute("UPDATE sessions SET projection_version=?,projection_hash=? WHERE id=?", [.integer(document.version), .text(ContentHash.sha256(json + markdown)), .text(sessionID.uuidString)])
    }

    func blockProjection(sessionID: UUID) throws {
        try database.transaction {
            try database.execute("UPDATE sessions SET projection_blocked=1 WHERE id=?", [.text(sessionID.uuidString)])
            try invalidateAgentSources(sessionID: sessionID)
        }
    }

    func transcriptDirectory(sessionID: UUID) throws -> URL {
        guard let row = try database.rows("SELECT document_directory FROM sessions WHERE id=?", [.text(sessionID.uuidString)]).first,
              let directory = row.string(0) else { throw ArchiveError.missingRecording(sessionID) }
        let url = rootURL.appendingPathComponent(directory, isDirectory: true)
        try validateRecordingPath(url)
        return url
    }

    func transcriptMarkdown(_ document: TranscriptDocument) -> String {
        var lines = ["# 转录", "", "<!-- momoagent session=\(document.sessionID.uuidString) version=\(document.version) generation=\(document.generation) -->", ""]
        for span in document.spans {
            lines += ["<!-- span=\(span.id.uuidString) chunk=\(span.chunkID.uuidString) start=\(span.frames.start) count=\(span.frames.count) -->", span.text, ""]
        }
        return lines.joined(separator: "\n")
    }


}


struct RecordingManifest: Codable { let sessionID: UUID; let chunks: [ChunkManifest] }
