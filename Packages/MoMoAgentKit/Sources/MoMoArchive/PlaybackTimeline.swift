import Foundation
import MoMoContracts

/// Immutable metadata only. A frozen timeline does not pin original audio against retention.
public struct ArchivedPlaybackPart: Sendable, Equatable {
    public let manifest: ChunkManifest
    public let manifestSHA256: String
    public let frames: FrameRange
    public let audioAvailable: Bool
}

public struct ArchivedPlaybackTimeline: Sendable {
    public let sessionID: UUID
    public let generation: Int64
    public let source: SourceReference?
    public let parts: [ArchivedPlaybackPart]
    public var windowSource: TimelineAudioSource? = nil
}

/// Derived previews use file metadata; actual play/seek/resume still verify the full audio hash.
public struct PlaybackPreviewFileStamp: Codable, Hashable, Sendable {
    public let size: Int64
    public let modified: Date
    public let created: Date
    public let fileNumber: UInt64
}

public struct WaveformPreparationEntry: Sendable {
    public let rowID: Int64
    public let timeline: ArchivedPlaybackTimeline
}

extension ArchiveStore {
    /// Bounded, newest-first backfill. Only ordinary metadata leaves this actor turn.
    public func waveformPreparationPage(beforeRowID: Int64? = nil, limit: Int = 16, cacheGeneration: UUID? = nil) throws -> [WaveformPreparationEntry] {
        let rows = try database.rows("""
            SELECT c.storage_sequence,c.manifest,c.manifest_hash,c.retention,c.relative_path,s.generation
            FROM chunks c JOIN sessions s ON s.id=c.session_id
            WHERE s.deleted=0 AND c.retention='present' AND c.storage_sequence < ?
              AND (? IS NULL OR NOT EXISTS (SELECT 1 FROM waveform_preparations w WHERE w.chunk_id=c.id
                  AND w.manifest_hash=c.manifest_hash AND w.generation=s.generation AND w.cache_generation=?))
            ORDER BY c.storage_sequence DESC LIMIT ?
            """, [.integer(beforeRowID ?? .max), cacheGeneration.map { .text($0.uuidString) } ?? .null, cacheGeneration.map { .text($0.uuidString) } ?? .null, .integer(Int64(max(1, min(32, limit))))])
        return try rows.map(waveformPreparationEntry)
    }

    /// Acknowledges only successfully persisted previews of the current archive generation.
    public func completeWaveformPreparation(_ entry: WaveformPreparationEntry, cacheGeneration: UUID) throws {
        try validatePlaybackTimeline(entry.timeline)
        for part in entry.timeline.parts where part.audioAvailable {
            try database.execute("INSERT OR REPLACE INTO waveform_preparations VALUES(?,?,?,?)", [
                .text(part.manifest.chunkID.uuidString), .text(part.manifestSHA256),
                .integer(entry.timeline.generation), .text(cacheGeneration.uuidString)
            ])
        }
    }

    public func waveformPreparationEntry(chunkID: UUID) throws -> WaveformPreparationEntry? {
        let rows = try database.rows("""
            SELECT c.storage_sequence,c.manifest,c.manifest_hash,c.retention,c.relative_path,s.generation
            FROM chunks c JOIN sessions s ON s.id=c.session_id
            WHERE c.id=? AND s.deleted=0 AND c.retention='present'
            """, [.text(chunkID.uuidString)])
        return try rows.first.map(waveformPreparationEntry)
    }

    private func waveformPreparationEntry(_ row: SQLRow) throws -> WaveformPreparationEntry {
        let envelope = try ManifestEnvelope(manifestData: row.requireData(1), manifestSHA256: row.requireString(2))
        let part = ArchivedPlaybackPart(manifest: envelope.manifest, manifestSHA256: envelope.manifestSHA256,
            frames: envelope.manifest.frames, audioAvailable: files.fileExists(atPath: rootURL.appendingPathComponent(try row.requireString(4)).path))
        return WaveformPreparationEntry(rowID: try row.requireInt(0), timeline: ArchivedPlaybackTimeline(
            sessionID: envelope.manifest.sessionID, generation: try row.requireInt(5), source: nil, parts: [part]))
    }

    /// Validate the frozen source and all original file identities without reading audio contents.
    public func playbackPreviewFileStamps(in timeline: ArchivedPlaybackTimeline) async throws -> [UUID: PlaybackPreviewFileStamp] {
        try Task.checkCancellation()
        try validatePlaybackTimeline(timeline)
        var result: [UUID: PlaybackPreviewFileStamp] = [:]
        for part in timeline.parts where part.audioAvailable && result[part.manifest.chunkID] == nil {
            result[part.manifest.chunkID] = try readPlaybackPreviewFileStamp(part)
            // No file handle or SQL statement survives this yield; reception and playback can run.
            await Task.yield()
            try Task.checkCancellation()
        }
        try validatePlaybackTimeline(timeline)
        return result
    }

    public func playbackPreviewFileStamp(for part: ArchivedPlaybackPart, in timeline: ArchivedPlaybackTimeline) throws -> PlaybackPreviewFileStamp {
        try validatePlaybackTimeline(timeline)
        guard part.audioAvailable, part.manifest.sessionID == timeline.sessionID,
              timeline.parts.contains(part) else { throw ArchiveError.staleSource }
        return try readPlaybackPreviewFileStamp(part)
    }

    private func readPlaybackPreviewFileStamp(_ part: ArchivedPlaybackPart) throws -> PlaybackPreviewFileStamp {
        #if DEBUG
        playbackPreviewStampReadCount += 1
        #endif
        let id = part.manifest.chunkID
        guard let row = try database.rows("SELECT manifest_hash,relative_path,retention FROM chunks WHERE id=?", [.text(id.uuidString)]).first,
              try row.requireString(0) == part.manifestSHA256, row.string(2) == "present" else { throw ArchiveError.staleSource }
        let url = rootURL.appendingPathComponent(try row.requireString(1))
        let manifestURL = url.appendingPathExtension("manifest.json")
        try validateRecordingPath(url)
        try validateRecordingPath(manifestURL)
        guard files.fileExists(atPath: url.path) else { throw ArchiveError.missingRecording(id) }
        guard files.fileExists(atPath: manifestURL.path),
              try manifestURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              try ContentHash.sha256(fileAt: manifestURL) == part.manifestSHA256 else { throw ArchiveError.missingRecording(id) }
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size == part.manifest.byteCount,
              let modified = attributes[.modificationDate] as? Date,
              let created = attributes[.creationDate] as? Date,
              let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { throw ArchiveError.missingRecording(id) }
        return PlaybackPreviewFileStamp(size: size, modified: modified, created: created, fileNumber: number)
    }

    public func playbackTimelines(sources: [TimelineAudioSource]) throws -> [ArchivedPlaybackTimeline] {
        return try sources.map { source in
            try validatePlaybackIdentity(sessionID: source.sessionID, generation: source.generation, source: nil)
            // A short timeline selection must not decode every manifest in a day-long recording.
            let rows = try database.rows("""
                SELECT manifest,manifest_hash,retention,relative_path FROM chunks
                WHERE session_id=? AND epoch_id=?
                  AND start_frame < ?
                  AND end_frame > ?
                ORDER BY start_frame,id
                """, [.text(source.sessionID.uuidString), .text(source.epochID.uuidString),
                       .integer(source.frames.end), .integer(source.frames.start)])
            let parts = try playbackParts(rows).map { part -> ArchivedPlaybackPart in
                let start = max(part.frames.start, source.frames.start), end = min(part.frames.end, source.frames.end)
                return ArchivedPlaybackPart(manifest: part.manifest, manifestSHA256: part.manifestSHA256,
                    frames: try FrameRange(start: start, count: end - start), audioAvailable: part.audioAvailable)
            }
            return ArchivedPlaybackTimeline(sessionID: source.sessionID, generation: source.generation,
                source: nil, parts: parts, windowSource: source)
        }
    }

    /// One actor turn freezes the received set, including holes/expired files, without leasing it all.
    public func playbackTimeline(sessionID: UUID, expectedGeneration: Int64,
                                 source: SourceReference? = nil, additionalSources: [SourceReference] = []) throws -> ArchivedPlaybackTimeline {
        try validatePlaybackIdentity(sessionID: sessionID, generation: expectedGeneration, source: source)
        guard additionalSources.allSatisfy({ $0.sessionID == sessionID && $0.generation == expectedGeneration }),
              additionalSources.isEmpty || source != nil else { throw ArchiveError.staleSource }
        try validateSources(additionalSources)
        let ranges: [TranscriptAudioRange]?
        if let source {
            let document = try readTranscript(sessionID: sessionID)
            let requested = [source] + additionalSources
            guard Set(requested.map(\.spanID)).count == requested.count else { throw ArchiveError.staleSource }
            let spans = Dictionary(uniqueKeysWithValues: document.spans.map { ($0.id, $0) })
            ranges = try requested.flatMap { reference in
                guard let span = spans[reference.spanID] else { throw ArchiveError.staleSource }
                return span.sourceRanges
            }
        } else { ranges = nil }
        let rows: [SQLRow]
        if let ranges {
            rows = try Set(ranges.map(\.chunkID)).flatMap { id in
                try database.rows("SELECT manifest,manifest_hash,retention,relative_path FROM chunks WHERE id=? AND session_id=?",
                    [.text(id.uuidString), .text(sessionID.uuidString)])
            }
        } else {
          rows = try database.rows("""
            SELECT c.manifest,c.manifest_hash,c.retention,c.relative_path FROM chunks c
            JOIN epochs e ON e.id=c.epoch_id WHERE c.session_id=?
            ORDER BY e.wall_clock_anchor,c.epoch_id,c.start_frame,c.id
            """, [.text(sessionID.uuidString)])
        }
        let chunks = try playbackParts(rows)
        let parts: [ArchivedPlaybackPart]
        if let ranges {
            let byID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.manifest.chunkID, $0) })
            parts = try ranges.map { range in
                guard let chunk = byID[range.chunkID], chunk.manifest.frames.contains(range.frames) else {
                    throw ArchiveError.invalidTranscript
                }
                return ArchivedPlaybackPart(manifest: chunk.manifest, manifestSHA256: chunk.manifestSHA256,
                                            frames: range.frames, audioAvailable: chunk.audioAvailable)
            }
        } else { parts = chunks }
        return ArchivedPlaybackTimeline(sessionID: sessionID, generation: expectedGeneration, source: source, parts: parts)
    }

    private func playbackParts(_ rows: [SQLRow]) throws -> [ArchivedPlaybackPart] {
        try rows.map { row in
            let envelope = try ManifestEnvelope(manifestData: row.requireData(0), manifestSHA256: row.requireString(1))
            let relativePath = try row.requireString(3)
            let available = row.string(2) == "present"
                && files.fileExists(atPath: rootURL.appendingPathComponent(relativePath).path)
            return ArchivedPlaybackPart(manifest: envelope.manifest, manifestSHA256: envelope.manifestSHA256,
                                        frames: envelope.manifest.frames, audioAvailable: available)
        }
    }

    public func validatePlaybackTimeline(_ timeline: ArchivedPlaybackTimeline) throws {
        try validatePlaybackIdentity(sessionID: timeline.sessionID, generation: timeline.generation, source: timeline.source)
    }

    /// Cheap clock-poll barrier for an already validated, immutable target. Append-only ASR cannot
    /// alter its cited span; edits/deletes advance generation. Keep Files' projection barrier too.
    /// Initial playback, prepare, seek and resume still use full source/file validation below.
    public func validateActivePlaybackTimeline(_ timeline: ArchivedPlaybackTimeline) throws {
        guard let row = try database.rows("SELECT deleted,generation,projection_blocked FROM sessions WHERE id=?",
            [.text(timeline.sessionID.uuidString)]).first else { throw ArchiveError.missingRecording(timeline.sessionID) }
        guard try row.requireInt(0) == 0 else { throw ArchiveError.sessionDeleted(timeline.sessionID) }
        guard try row.requireInt(1) == timeline.generation else { throw ArchiveError.staleSource }
        if timeline.source != nil, try row.requireInt(2) != 0 { throw ArchiveError.projectionConflict }
    }

    /// Rechecks deletion, source revision, immutable manifest and actual file hash before every play/seek/resume.
    public func acquirePlaybackPart(_ part: ArchivedPlaybackPart, in timeline: ArchivedPlaybackTimeline) throws -> AudioPlaybackPart {
        try validatePlaybackTimeline(timeline)
        guard timeline.parts.contains(part), part.manifest.sessionID == timeline.sessionID,
              part.manifest.frames.contains(part.frames),
              let row = try database.rows("SELECT manifest_hash FROM chunks WHERE id=?", [.text(part.manifest.chunkID.uuidString)]).first,
              try row.requireString(0) == part.manifestSHA256 else { throw ArchiveError.staleSource }
        return AudioPlaybackPart(lease: try acquireAudioLease(chunkID: part.manifest.chunkID), frames: part.frames)
    }

    private func validatePlaybackIdentity(sessionID: UUID, generation: Int64, source: SourceReference?) throws {
        guard try !sessionIsDeleted(sessionID) else { throw ArchiveError.sessionDeleted(sessionID) }
        guard try sessionGeneration(sessionID) == generation else { throw ArchiveError.staleSource }
        if let source {
            guard source.sessionID == sessionID, source.generation == generation else { throw ArchiveError.staleSource }
            try validateSources([source])
        }
    }
}
