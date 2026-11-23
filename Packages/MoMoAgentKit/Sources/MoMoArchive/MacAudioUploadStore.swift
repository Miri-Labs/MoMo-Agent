import Foundation
import MoMoContracts

public struct PendingMacAudioChunk: Sendable, Identifiable, Equatable {
    public let chunkID: UUID
    public let sessionID: UUID
    public let deviceID: UUID
    public let chunkSeq: Int
    public let recordedAt: Date
    public let durationSec: Double
    public let timezoneOffset: Int
    public let sourceKind: String
    public let codec: String
    public let sampleRate: Int
    public let audioSHA256: String
    public let audioURL: URL
    public let byteCount: Int64

    public var id: UUID { chunkID }
}

public struct MacAudioUploadCounts: Sendable, Equatable {
    public let pending: Int
    public let uploaded: Int
    public let failed: Int

    public init(pending: Int = 0, uploaded: Int = 0, failed: Int = 0) {
        self.pending = pending
        self.uploaded = uploaded
        self.failed = failed
    }
}

public struct MacRemoteTranscriptSpanInput: Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let recordedAt: Date
    public let endAt: Date?
    public let speaker: String?
    public let isOwner: Bool?
    public let timezoneOffset: Int?

    public init(
        id: UUID,
        text: String,
        recordedAt: Date,
        endAt: Date? = nil,
        speaker: String? = nil,
        isOwner: Bool? = nil,
        timezoneOffset: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.recordedAt = recordedAt
        self.endAt = endAt
        self.speaker = speaker
        self.isOwner = isOwner
        self.timezoneOffset = timezoneOffset
    }
}

extension ArchiveStore {
    /// Returns locally stored audio chunks that have not yet been uploaded & confirmed by Mac,
    /// prioritized newest-first so live Watch/Earphone speech is transcribed by Mac first, while
    /// assigning strictly chronological per-session `chunkSeq` and true chunk wall-clock timestamps.
    public func pendingMacAudioUploads(limit: Int = 16) throws -> [PendingMacAudioChunk] {
        guard (1...128).contains(limit) else { throw ArchiveError.invalidQuery }
        let rows = try database.rows("""
            WITH ordered AS (
                SELECT c.id, c.session_id, c.manifest, c.relative_path, c.sealed_at, c.storage_sequence,
                       ROW_NUMBER() OVER (
                           PARTITION BY c.session_id
                           ORDER BY (c.wall_clock_anchor + CAST(c.start_frame AS REAL) / MAX(1.0, c.timebase_hz)) ASC,
                                    c.storage_sequence ASC
                       ) - 1 AS session_seq
                FROM chunks c
                JOIN sessions s ON s.id = c.session_id
                WHERE s.deleted = 0
            )
            SELECT o.id, o.session_id, o.manifest, o.relative_path, o.session_seq
            FROM ordered o
            JOIN chunks c ON c.id = o.id
            LEFT JOIN mac_audio_uploads u ON u.chunk_id = o.id
            WHERE c.retention = 'present'
              AND (u.upload_state IS NULL OR u.upload_state != 'uploaded')
            ORDER BY o.sealed_at DESC, o.storage_sequence DESC
            LIMIT ?
            """, [.integer(Int64(limit))])

        var out: [PendingMacAudioChunk] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            let chunkID = try row.requireUUID(0)
            let sessionID = try row.requireUUID(1)
            let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(2))
            let relPath = try row.requireString(3)
            let seq = Int(try row.requireInt(4))
            let url = rootURL.appendingPathComponent(relPath)
            guard files.fileExists(atPath: url.path) else { continue }
            let timebase = manifest.timebaseHz > 0 ? manifest.timebaseHz : Double(max(16_000, manifest.sampleRate))
            // `manifest.wallClockAnchor` is the epoch start; each chunk starts at `wallClockAnchor + frames.start / timebaseHz`.
            let chunkRecordedAt = manifest.wallClockAnchor.addingTimeInterval(Double(manifest.frames.start) / timebase)
            let duration = max(0.5, Double(manifest.frames.count) / timebase)
            let srcKind: String = (manifest.sourceKind == .phone) ? "earphone" : "watch"
            out.append(PendingMacAudioChunk(
                chunkID: chunkID,
                sessionID: sessionID,
                deviceID: manifest.sourceDeviceID,
                chunkSeq: seq,
                recordedAt: chunkRecordedAt,
                durationSec: duration,
                timezoneOffset: manifest.timezoneOffset,
                sourceKind: srcKind,
                codec: manifest.codec.rawValue,
                sampleRate: Int(manifest.sampleRate),
                audioSHA256: manifest.audioSHA256,
                audioURL: url,
                byteCount: manifest.byteCount
            ))
        }
        return out
    }

    public func markMacAudioChunkUploaded(chunkID: UUID, remoteSHA256: String, remoteSourceID: String) throws {
        try database.execute("""
            INSERT INTO mac_audio_uploads(chunk_id, upload_state, remote_sha256, remote_source_id, uploaded_at, last_error)
            VALUES(?, 'uploaded', ?, ?, ?, NULL)
            ON CONFLICT(chunk_id) DO UPDATE SET
                upload_state='uploaded', remote_sha256=excluded.remote_sha256,
                remote_source_id=excluded.remote_source_id, uploaded_at=excluded.uploaded_at, last_error=NULL
            """, [
            .text(chunkID.uuidString),
            .text(remoteSHA256),
            .text(remoteSourceID),
            .double(Date().timeIntervalSince1970)
        ])
    }

    public func markMacAudioChunkFailed(chunkID: UUID, error: String) throws {
        try database.execute("""
            INSERT INTO mac_audio_uploads(chunk_id, upload_state, last_error)
            VALUES(?, 'failed', ?)
            ON CONFLICT(chunk_id) DO UPDATE SET
                upload_state=CASE WHEN upload_state='uploaded' THEN 'uploaded' ELSE 'failed' END,
                last_error=excluded.last_error
            """, [
            .text(chunkID.uuidString),
            .text(String(error.prefix(400)))
        ])
    }

    /// Returns uploaded chunk IDs whose local `transcription_jobs` row is still pending so iPhone
    /// can poll Mac's `/v1/audio/chunks/batch-status` and mark silent/done/failed chunks cleanly.
    public func uploadedUnsettledMacAudioChunkIDs(limit: Int = 64) throws -> [UUID] {
        guard (1...256).contains(limit) else { throw ArchiveError.invalidQuery }
        let rows = try database.rows("""
            SELECT u.chunk_id
            FROM mac_audio_uploads u
            JOIN transcription_jobs j ON j.chunk_id = u.chunk_id
            JOIN chunks c ON c.id = u.chunk_id
            JOIN sessions s ON s.id = c.session_id
            WHERE u.upload_state = 'uploaded' AND s.deleted = 0 AND j.state != 'complete' AND j.state != 'failed'
            ORDER BY u.uploaded_at DESC
            LIMIT ?
            """, [.integer(Int64(limit))])
        return rows.compactMap { try? $0.requireUUID(0) }
    }

    /// Updates local `transcription_jobs` from Mac's chunk transcription status (`done` / `silent` / `failed`)
    /// so Timeline & RecordingSummary leave "等待 Mac 转录" cleanly without requiring local iPhone ASR.
    public func markMacAudioChunksStatus(_ statuses: [UUID: String]) throws -> Int {
        guard !statuses.isEmpty else { return 0 }
        var changed = 0
        try database.transaction {
            for (chunkID, rawStatus) in statuses {
                let lower = rawStatus.lowercased()
                let jobState: String
                let errorCode: SQLValue
                switch lower {
                case "done":
                    jobState = "complete"
                    errorCode = .null
                case "silent":
                    jobState = "complete"
                    errorCode = .text("no_speech")
                case "failed":
                    jobState = "failed"
                    errorCode = .text("mac_transcription_failed")
                default:
                    continue
                }
                try database.execute(
                    "UPDATE transcription_jobs SET state = ?, error_code = ? WHERE chunk_id = ? AND (state != ? OR COALESCE(error_code, '') != COALESCE(?, ''))",
                    [.text(jobState), errorCode, .text(chunkID.uuidString), .text(jobState), errorCode]
                )
                changed += 1
            }
        }
        return changed
    }

    public func macAudioUploadCounts() throws -> MacAudioUploadCounts {
        let pending = try database.rows("""
            SELECT COUNT(*) FROM chunks c
            JOIN sessions s ON s.id = c.session_id
            LEFT JOIN mac_audio_uploads u ON u.chunk_id = c.id
            WHERE c.retention = 'present' AND s.deleted = 0
              AND (u.upload_state IS NULL OR u.upload_state = 'pending')
            """).first?.integer(0) ?? 0
        let uploaded = try database.rows(
            "SELECT COUNT(*) FROM mac_audio_uploads WHERE upload_state = 'uploaded'"
        ).first?.integer(0) ?? 0
        let failed = try database.rows("""
            SELECT COUNT(*) FROM mac_audio_uploads u
            JOIN chunks c ON c.id = u.chunk_id
            JOIN sessions s ON s.id = c.session_id
            WHERE c.retention = 'present' AND s.deleted = 0 AND u.upload_state = 'failed'
            """).first?.integer(0) ?? 0
        return MacAudioUploadCounts(pending: Int(pending), uploaded: Int(uploaded), failed: Int(failed))
    }

    /// Returns session IDs whose audio has been uploaded to Mac so Mac owns their authoritative transcripts.
    public func macAuthoritativeSessionIDs() throws -> Set<UUID> {
        let rows = try database.rows("""
            SELECT DISTINCT c.session_id
            FROM chunks c
            JOIN mac_audio_uploads u ON u.chunk_id = c.id
            WHERE u.upload_state = 'uploaded'
            """)
        var ids: Set<UUID> = []
        ids.reserveCapacity(rows.count)
        for row in rows {
            if let uuid = try? row.requireUUID(0) {
                ids.insert(uuid)
            }
        }
        return ids
    }

    /// Caches a Mac-authoritative transcript into the local iPhone SQLite archive via `storeDocument`
    /// so Timeline, RecordingDetail, search, and "Discuss with MoMo" citations work seamlessly online & offline.
    public func cacheMacRemoteTranscript(
        sessionID: UUID,
        spans: [MacRemoteTranscriptSpanInput],
        macGeneration: Int64? = nil,
        macVersion: Int64? = nil
    ) throws {
        guard !spans.isEmpty else { return }
        guard let sessionRow = try database.rows(
            "SELECT generation, transcript_version, deleted FROM sessions WHERE id = ?",
            [.text(sessionID.uuidString)]
        ).first else { return }
        guard (sessionRow.integer(2) ?? 0) == 0 else { return }
        let currentGeneration = try sessionRow.requireInt(0)
        let currentVersion = try sessionRow.requireInt(1)

        // Load chunks ordered by their real wall-clock start (`wallClockAnchor + frames.start / timebaseHz`)
        let chunkRows = try database.rows("""
            SELECT id, epoch_id, manifest FROM chunks
            WHERE session_id = ?
            ORDER BY (wall_clock_anchor + CAST(start_frame AS REAL) / MAX(1.0, timebase_hz)) ASC, storage_sequence ASC
            """, [.text(sessionID.uuidString)])
        struct ChunkAnchor {
            let chunkID: UUID
            let epochID: UUID
            let chunkStartDate: Date
            let chunkEndDate: Date
            let timebaseHz: Double
            let frames: FrameRange
        }
        let anchors: [ChunkAnchor] = chunkRows.compactMap { r in
            guard let cid = try? r.requireUUID(0),
                  let eid = try? r.requireUUID(1),
                  let mdata = try? r.requireData(2),
                  let m = try? WireJSON.decode(ChunkManifest.self, from: mdata) else { return nil }
            let hz = m.timebaseHz > 0 ? m.timebaseHz : Double(max(16_000, m.sampleRate))
            let start = m.wallClockAnchor.addingTimeInterval(Double(m.frames.start) / hz)
            let end = start.addingTimeInterval(Double(m.frames.count) / hz)
            return ChunkAnchor(chunkID: cid, epochID: eid, chunkStartDate: start, chunkEndDate: end, timebaseHz: hz, frames: m.frames)
        }
        guard let firstAnchor = anchors.first else { return }

        var transcriptSpans: [TranscriptSpan] = []
        transcriptSpans.reserveCapacity(spans.count)
        var lastSpeaker: String?
        for sp in spans {
            let anchor = anchors.last(where: { $0.chunkStartDate <= sp.recordedAt }) ?? firstAnchor
            let offsetSec = max(0.0, sp.recordedAt.timeIntervalSince(anchor.chunkStartDate))
            let durSec = max(0.2, (sp.endAt ?? sp.recordedAt.addingTimeInterval(1.5)).timeIntervalSince(sp.recordedAt))
            let hz = anchor.timebaseHz
            let maxStartOffset = max(0, anchor.frames.count - 1)
            let startOffset = min(maxStartOffset, Int64((offsetSec * hz).rounded()))
            let startFrame = anchor.frames.start + startOffset
            let remaining = max(1, anchor.frames.end - startFrame)
            let countFrames = min(remaining, max(1600, Int64((durSec * hz).rounded())))
            let range = try FrameRange(start: startFrame, count: max(1, countFrames))
            let isNewTurn = sp.speaker != nil && sp.speaker != lastSpeaker
            lastSpeaker = sp.speaker
            transcriptSpans.append(TranscriptSpan(
                id: sp.id,
                chunkID: anchor.chunkID,
                frames: range,
                text: sp.text,
                speaker: sp.speaker,
                sourceRanges: [TranscriptAudioRange(chunkID: anchor.chunkID, frames: range)],
                attribution: nil,
                startsNewSpeakerTurn: isNewTurn
            ))
        }

        // Preserve Mac's exact (generation, version) when higher so "Discuss with MoMo" recording references match Mac 1:1.
        let targetGeneration = max(currentGeneration, macGeneration ?? currentGeneration)
        let targetVersion: Int64
        if targetGeneration > currentGeneration, let mv = macVersion, mv > 0 {
            targetVersion = mv
        } else if let mv = macVersion, mv > currentVersion {
            targetVersion = mv
        } else {
            targetVersion = currentVersion + 1
        }

        let doc = TranscriptDocument(
            sessionID: sessionID,
            version: targetVersion,
            generation: targetGeneration,
            spans: transcriptSpans,
            updatedAt: Date()
        )

        try database.transaction {
            if targetGeneration != currentGeneration {
                try database.execute(
                    "UPDATE sessions SET generation = ? WHERE id = ?",
                    [.integer(targetGeneration), .text(sessionID.uuidString)]
                )
            }
            // Remove any conflicting version row if targetVersion already existed from an older generation
            try database.execute(
                "DELETE FROM transcript_versions WHERE session_id = ? AND version >= ?",
                [.text(sessionID.uuidString), .integer(targetVersion)]
            )
            _ = try storeDocument(doc, invalidatesExistingSources: targetGeneration != currentGeneration)
            // Mark uploaded chunks of this session as complete so Timeline & RecordingSummary reflect finished state
            try database.execute("""
                UPDATE transcription_jobs
                SET state = 'complete', error_code = NULL
                WHERE chunk_id IN (
                    SELECT c.id FROM chunks c
                    JOIN mac_audio_uploads u ON u.chunk_id = c.id
                    WHERE c.session_id = ? AND u.upload_state = 'uploaded'
                ) AND state != 'complete'
                """, [.text(sessionID.uuidString)])
        }
    }
}
