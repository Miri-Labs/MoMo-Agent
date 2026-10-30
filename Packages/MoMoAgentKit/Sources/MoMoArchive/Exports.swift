import Foundation
import MoMoContracts

public enum RecordingExportContent: String, Sendable, CaseIterable {
    case transcript, audio, audioAndTranscript
    var includesAudio: Bool { self != .transcript }
    var includesTranscript: Bool { self != .audio }
}

public enum ArchiveExportError: Error, Sendable, Equatable {
    case audioUnavailable, sourceChanged, unsafeTemporaryPath, noTranscriptInRange
}

/// An immutable, user-requested snapshot. Keep its files until the system share completion callback.
public struct ArchiveExport: Identifiable, Sendable {
    public let id: UUID
    public let fileURLs: [URL]
    public let createdAt: Date
    let directory: URL
    let source: Source

    enum Source: Sendable {
        case recording(RecordingExportSource)
        case timeline(references: [SourceReference], generations: [UUID: Int64])
    }
}

struct RecordingExportSource: Sendable {
    let sessionID: UUID
    let generation: Int64
    let transcriptVersion: Int64
    let content: RecordingExportContent
    let chunkIDs: [UUID]
    let exportedAudioChunkIDs: Set<UUID>
}

struct ExportFileInput: Sendable {
    let source: URL
    let filename: String
    let byteCount: Int64
    let sha256: String
}

struct RecordingExportTicket: Sendable {
    let export: ArchiveExport
    let inputs: [ExportFileInput]
    let index: Data
    let leaseIDs: [UUID]
}

private struct RecordingExportIndex: Encodable {
    let sessionID: UUID
    let generation: Int64
    let transcriptVersion: Int64
    let exportedAt: Date
    let scope = "received_on_phone_snapshot"
    let chunks: [Chunk]
    let epochs: [Epoch]
    struct Chunk: Encodable {
        let manifest: ChunkManifest
        let audioFilename: String?
        let retention: String
        /// Nil only when audio bytes are included. Never infer silence from an omitted file.
        let audioOmission: String?
    }
    struct Epoch: Encodable {
        let epochID: UUID
        let timebaseHz: Double?
        let closedAtFrame: Int64?
        let observedThroughFrame: Int64
        let unknownTailFromFrame: Int64?
        let notReceived: [FrameRange]
    }
}

extension ArchiveStore {
    public func prepareRecordingExport(sessionID: UUID, expectedGeneration: Int64,
                                       expectedTranscriptVersion: Int64,
                                       content: RecordingExportContent) async throws -> ArchiveExport {
        try Task.checkCancellation()
        let ticket = try beginRecordingExport(sessionID: sessionID, expectedGeneration: expectedGeneration,
                                              expectedTranscriptVersion: expectedTranscriptVersion, content: content)
        defer { releaseExportLeases(ticket) }
        do {
            // No database transaction or open file handle crosses this await. The worker owns each copy handle.
            let worker = Task.detached(priority: .utility) { try ExportFileCopy.stage(ticket) }
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            try validateExportSource(ticket.export)
            return ticket.export
        } catch {
            // A cleanup failure must be visible; cold-start cleanup retries any remaining directory.
            try removeExport(ticket.export)
            throw error
        }
    }

    func beginRecordingExport(sessionID: UUID, expectedGeneration: Int64, expectedTranscriptVersion: Int64,
                              content: RecordingExportContent) throws -> RecordingExportTicket {
        try validateExportSession(sessionID, generation: expectedGeneration, transcriptVersion: expectedTranscriptVersion)
        var inputs: [ExportFileInput] = []
        if content.includesTranscript {
            _ = try readTranscript(sessionID: sessionID)
            for filename in ["transcript.md", "transcript.json"] {
                inputs.append(try transcriptExportInput(sessionID: sessionID, filename: filename))
            }
        }
        let rows = try database.rows("SELECT id,manifest,manifest_hash,relative_path,retention FROM chunks WHERE session_id=? ORDER BY rowid", [.text(sessionID.uuidString)])
        guard !rows.isEmpty else { throw ArchiveError.missingRecording(sessionID) }
        var leases: [UUID] = []
        var chunks: [RecordingExportIndex.Chunk] = []
        do {
            for (offset, row) in rows.enumerated() {
                try Task.checkCancellation()
                let envelope = try ManifestEnvelope(manifestData: row.requireData(1), manifestSHA256: row.requireString(2))
                let manifest = envelope.manifest
                guard manifest.sessionID == sessionID, manifest.chunkID == (try row.requireUUID(0)) else { throw ArchiveError.invalidInbox }
                let retention = try row.requireString(4)
                guard ["present", "expired", "expiry_pending", "missing_unexpected"].contains(retention) else {
                    throw ArchiveError.database(11)
                }
                var filename: String?
                var omission: String? = content.includesAudio ? retention : "not_requested"
                if content.includesAudio && retention == "present" {
                    let source = rootURL.appendingPathComponent(try row.requireString(3))
                    try validateRecordingPath(source)
                    // Files can be removed outside the App before reconciliation marks the row missing.
                    // Only absence is skippable; bad bytes, unsafe paths and I/O errors still fail closed.
                    let values: URLResourceValues?
                    do { values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
                    catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                        values = nil
                    }
                    guard let values else {
                        chunks.append(.init(manifest: manifest, audioFilename: nil, retention: retention,
                                            audioOmission: "missing_unexpected"))
                        continue
                    }
                    guard values.isRegularFile == true, values.fileSize.map(Int64.init) == manifest.byteCount else {
                        throw ArchiveError.byteCountMismatch
                    }
                    let manifestURL = source.appendingPathExtension("manifest.json")
                    try validateRecordingPath(manifestURL)
                    let manifestValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard manifestValues.isRegularFile == true, manifestValues.fileSize == envelope.manifestData.count else {
                        throw ArchiveError.checksumMismatch
                    }
                    guard try ContentHash.sha256(fileAt: manifestURL) == envelope.manifestSHA256 else { throw ArchiveError.checksumMismatch }
                    let audioFilename = String(format: "%05d", offset + 1) + "-" + manifest.chunkID.uuidString + audioExtension(manifest.codec)
                    filename = audioFilename
                    omission = nil
                    inputs.append(ExportFileInput(source: source, filename: audioFilename, byteCount: manifest.byteCount, sha256: manifest.audioSHA256))
                    // The copy worker validates every audio byte while the lease blocks retention/deletion.
                    let leaseID = UUID()
                    audioLeases[leaseID] = manifest.chunkID
                    leases.append(leaseID)
                }
                chunks.append(.init(manifest: manifest, audioFilename: filename, retention: retention, audioOmission: omission))
            }
            let exportedAudioChunkIDs = Set(chunks.filter { $0.audioFilename != nil }.map { $0.manifest.chunkID })
            guard !content.includesAudio || !exportedAudioChunkIDs.isEmpty else { throw ArchiveExportError.audioUnavailable }
            let coverage = try recordingCoverage(sessionID: sessionID, configurationFingerprint: nil)
            let id = UUID()
            let directory = exportRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            let createdAt = Date()
            let artifact = ArchiveExport(id: id, fileURLs: (inputs.map(\.filename) + ["recording.json", "README.txt"]).map { directory.appendingPathComponent($0) },
                createdAt: createdAt, directory: directory, source: .recording(RecordingExportSource(sessionID: sessionID, generation: expectedGeneration,
                transcriptVersion: expectedTranscriptVersion, content: content, chunkIDs: chunks.map { $0.manifest.chunkID },
                exportedAudioChunkIDs: exportedAudioChunkIDs)))
            let index = try WireJSON.encode(RecordingExportIndex(sessionID: sessionID, generation: expectedGeneration,
                transcriptVersion: expectedTranscriptVersion, exportedAt: createdAt, chunks: chunks,
                epochs: coverage.epochs.map { .init(epochID: $0.epochID, timebaseHz: $0.timebaseHz,
                    closedAtFrame: $0.closedAtFrame, observedThroughFrame: $0.observedThroughFrame,
                    unknownTailFromFrame: $0.unknownTailFromFrame, notReceived: $0.notReceived) }))
            try validateExportTemporaryPath(directory)
            return RecordingExportTicket(export: artifact, inputs: inputs, index: index, leaseIDs: leases)
        } catch {
            for id in leases { audioLeases.removeValue(forKey: id) }
            throw error
        }
    }

    func releaseExportLeases(_ ticket: RecordingExportTicket) {
        for id in ticket.leaseIDs { audioLeases.removeValue(forKey: id) }
    }

    /// Recheck just before handing the snapshot to a system activity.
    public func validateExportSource(_ artifact: ArchiveExport) throws {
        try validateExportTemporaryPath(artifact.directory)
        switch artifact.source {
        case .timeline(let references, let generations):
            for (id, generation) in generations {
                guard let row = try database.rows("SELECT generation FROM sessions WHERE id=? AND deleted=0", [.text(id.uuidString)]).first,
                      row.integer(0) == generation else { throw ArchiveExportError.sourceChanged }
            }
            for start in stride(from: 0, to: references.count, by: Self.maximumSourceReferences) {
                try validateSources(Array(references[start..<min(start + Self.maximumSourceReferences, references.count)]))
            }
        case .recording(let source):
            try validateRecordingExportSource(source)
        }
    }

    private func validateRecordingExportSource(_ source: RecordingExportSource) throws {
        try validateExportSession(source.sessionID, generation: source.generation, transcriptVersion: source.transcriptVersion)
        let rows = try database.rows("SELECT id,retention FROM chunks WHERE session_id=? ORDER BY rowid", [.text(source.sessionID.uuidString)])
        guard try rows.map({ try $0.requireUUID(0) }) == source.chunkIDs else { throw ArchiveExportError.sourceChanged }
        if source.content.includesAudio {
            // Omitted expired/missing parts are described in the frozen index, not required to reappear.
            // Included parts must still belong to the current retained recording before sharing.
            for row in rows where source.exportedAudioChunkIDs.contains(try row.requireUUID(0)) {
                guard row.string(1) == "present" else { throw ArchiveExportError.audioUnavailable }
            }
        }
        if source.content.includesTranscript {
            _ = try transcriptExportInput(sessionID: source.sessionID, filename: "transcript.md")
            _ = try transcriptExportInput(sessionID: source.sessionID, filename: "transcript.json")
        }
    }

    public func removeExport(_ artifact: ArchiveExport) throws {
        try validateExportTemporaryPath(artifact.directory)
        if files.fileExists(atPath: artifact.directory.path) { try files.removeItem(at: artifact.directory) }
    }

    /// Cold start only, before any share activity is created. Never call while an extension may be reading a snapshot.
    public func removeAbandonedExports() throws {
        try validateExportTemporaryPath(exportRoot.appendingPathComponent(UUID().uuidString))
        guard files.fileExists(atPath: exportRoot.path) else { return }
        for directory in try files.contentsOfDirectory(at: exportRoot, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: directory.lastPathComponent) != nil else { throw ArchiveExportError.unsafeTemporaryPath }
            try validateExportTemporaryPath(directory)
            try files.removeItem(at: directory)
        }
    }

    var exportRoot: URL { rootURL.appendingPathComponent("tmp/Exports", isDirectory: true) }

    private func transcriptExportInput(sessionID: UUID, filename: String) throws -> ExportFileInput {
        // Bound externally editable files before the existing projection equality check reads them.
        let url = try transcriptDirectory(sessionID: sessionID).appendingPathComponent(filename)
        try validateRecordingPath(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 8 * 1_024 * 1_024 else {
            throw ArchiveError.invalidTranscript
        }
        let verified = try transcriptFileURL(sessionID: sessionID, markdown: filename.hasSuffix(".md"))
        return ExportFileInput(source: verified, filename: filename, byteCount: Int64(size),
                               sha256: try ContentHash.sha256(fileAt: verified))
    }

    private func validateExportSession(_ id: UUID, generation: Int64, transcriptVersion: Int64) throws {
        guard let row = try database.rows("SELECT generation,transcript_version,deleted,projection_blocked FROM sessions WHERE id=?", [.text(id.uuidString)]).first else { throw ArchiveError.missingRecording(id) }
        guard row.integer(2) == 0 else { throw ArchiveError.sessionDeleted(id) }
        guard row.integer(0) == generation, row.integer(1) == transcriptVersion else { throw ArchiveExportError.sourceChanged }
        guard row.integer(3) == 0 else { throw ArchiveError.projectionConflict }
    }

    func validateExportTemporaryPath(_ directory: URL) throws {
        let root = rootURL.standardizedFileURL
        guard directory.standardizedFileURL.deletingLastPathComponent() == exportRoot.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil else { throw ArchiveExportError.unsafeTemporaryPath }
        var cursor = root
        for component in ["tmp", "Exports", directory.lastPathComponent] {
            cursor.appendPathComponent(component, isDirectory: true)
            do {
                let attributes = try files.attributesOfItem(atPath: cursor.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveExportError.unsafeTemporaryPath }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        }
    }
}
