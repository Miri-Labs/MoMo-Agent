import Foundation
import MoMoContracts

public enum ProcessingFailureCode: String, Sendable {
    case audioRead = "audio_read_failed", invalidAudio = "audio_invalid", audioUnavailable = "audio_unavailable"
    case recognition = "speech_processing_failed"
}

public enum ProcessingWaitState: Sendable, Equatable {
    case idle, awaitingAudio, awaitingContext, unavailableAudio, queued
    case retryScheduled(Date)
}

extension ArchiveStore {
    public func deferEpochAnalysis(ticket: EpochAnalysisTicket, code: ProcessingFailureCode, now: Date = Date()) throws {
        do {
            try database.transaction {
                try validateEpochTicket(ticket)
                let failedFrames = try analysisInputRange(ticket.inputs, start: ticket.checkpoint?.sourceFrame, end: ticket.boundary.endFrame)
                try saveProcessingFailure(sessionID: ticket.sessionID, epochID: ticket.epochID, generation: ticket.expectedGeneration,
                    fingerprint: ticket.configurationFingerprint, stage: .analysis, workID: ticket.inputIdentity,
                    frames: failedFrames, code: code, now: now)
                if let batchExecution = ticket.batchExecution {
                    try deferBatchSlice(batchID: batchExecution.batchID, sessionID: ticket.sessionID,
                        epochID: ticket.epochID, frames: failedFrames)
                }
                try database.execute("UPDATE analysis_epochs SET attempt_id=NULL WHERE epoch_id=? AND configuration_hash=?",
                    [.text(ticket.epochID.uuidString), .text(ticket.configurationFingerprint)])
            }
        } catch {
            try cancelEpochAnalysis(ticket: ticket)
            throw error
        }
        try cancelEpochAnalysis(ticket: ticket)
    }

    public func deferTranscriptionWindow(ticket: TranscriptionWindowTicket, code: ProcessingFailureCode, now: Date = Date()) throws {
        do {
            try database.transaction {
                try validateWindowTicket(ticket)
                try saveProcessingFailure(sessionID: ticket.window.sessionID, epochID: ticket.window.epochID, generation: ticket.expectedGeneration,
                    fingerprint: ticket.window.configurationFingerprint, stage: .transcription, workID: ticket.window.id,
                    frames: ticket.window.coreFrames, code: code, now: now)
                if let batchExecution = ticket.batchExecution {
                    try deferBatchWindow(batchID: batchExecution.batchID, window: ticket.window)
                }
                try database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL WHERE id=?", [.text(ticket.window.id)])
            }
        } catch {
            try cancelTranscriptionWindow(ticket: ticket)
            throw error
        }
        try cancelTranscriptionWindow(ticket: ticket)
    }

    func processingIsDeferred(epochID: UUID, generation: Int64, fingerprint: String,
                              stage: TranscriptionFailureScope.Stage, workID: String, now: Date = Date()) throws -> Bool {
        try !database.rows("SELECT 1 FROM processing_failures WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage=? AND work_id=? AND error_code!='audio_unavailable' AND retry_after>?",
            [.text(epochID.uuidString), .integer(generation), .text(fingerprint), .text(stage.rawValue), .text(workID), .double(now.timeIntervalSince1970)]).isEmpty
    }

    func saveProcessingFailure(sessionID: UUID, epochID: UUID, generation: Int64, fingerprint: String,
                               stage: TranscriptionFailureScope.Stage, workID: String, frames: FrameRange,
                               code: ProcessingFailureCode, now: Date = Date()) throws {
        let key: [SQLValue] = [.text(epochID.uuidString), .integer(generation), .text(fingerprint), .text(stage.rawValue), .text(workID)]
        let previous = try database.rows("SELECT attempts FROM processing_failures WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage=? AND work_id=?", key).first?.requireInt(0) ?? 0
        let attempts = min(previous + 1, 32)
        let delay = min(300, 5 * pow(2, Double(attempts - 1)))
        try database.execute("""
            INSERT INTO processing_failures(session_id,epoch_id,generation,configuration_hash,stage,work_id,start_frame,end_frame,error_code,attempts,retry_after)
            VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(epoch_id,generation,configuration_hash,stage,work_id)
            DO UPDATE SET error_code=excluded.error_code,attempts=excluded.attempts,retry_after=excluded.retry_after
            """, [.text(sessionID.uuidString)] + key + [.integer(frames.start), .integer(frames.end), .text(code.rawValue), .integer(attempts), .double(now.addingTimeInterval(delay).timeIntervalSince1970)])
    }

    func analysisInputRange(_ inputs: [ArchivedAudioInput], start: Int64?, end: Int64? = nil) throws -> FrameRange {
        guard let first = inputs.first, let last = inputs.last else { throw ArchiveError.invalidTranscript }
        let lower = start ?? first.envelope.manifest.frames.start
        return try FrameRange(start: lower, count: min(last.envelope.manifest.frames.end, end ?? .max) - lower)
    }

    func clearProcessingFailures(epochID: UUID, generation: Int64, fingerprint: String,
                                  stage: TranscriptionFailureScope.Stage, frames: FrameRange) throws {
        try database.execute("DELETE FROM processing_failures WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage=? AND start_frame>=? AND end_frame<=?",
            [.text(epochID.uuidString), .integer(generation), .text(fingerprint), .text(stage.rawValue), .integer(frames.start), .integer(frames.end)])
    }

    /// Called only after the claim loop has no runnable work. Unknown capture end is never a blocker.
    public func processingWaitState(configurationFingerprint: String, sessionID: UUID? = nil) throws -> ProcessingWaitState {
        guard ContentHash.isValid(configurationFingerprint) else { throw ArchiveError.invalidQuery }
        let filter = sessionID.map { SQLValue.text($0.uuidString) } ?? .null
        let nowSeconds = Date().timeIntervalSince1970
        let deferred = try database.rows("SELECT MIN(f.retry_after) FROM processing_failures f JOIN sessions s ON s.id=f.session_id WHERE s.deleted=0 AND s.projection_blocked=0 AND s.generation=f.generation AND f.configuration_hash=? AND f.error_code!='audio_unavailable' AND f.retry_after>? AND (? IS NULL OR s.id=?)",
            [.text(configurationFingerprint), .double(nowSeconds), filter, filter]).first?.double(0)
        if let deferred { return .retryScheduled(Date(timeIntervalSince1970: deferred)) }
        let unavailableFailures = try database.rows("SELECT 1 FROM processing_failures f JOIN sessions s ON s.id=f.session_id WHERE s.deleted=0 AND s.projection_blocked=0 AND s.generation=f.generation AND f.configuration_hash=? AND f.error_code='audio_unavailable' AND (? IS NULL OR s.id=?) LIMIT 1",
            [.text(configurationFingerprint), filter, filter])
        // Analysis can already be complete when a pending ASR window loses its
        // audio. Its missing context must not be hidden by an open recording tail.
        let unavailableWindows = try database.rows("""
            SELECT 1 FROM analysis_windows w JOIN sessions s ON s.id=w.session_id
            JOIN chunks c ON c.epoch_id=w.epoch_id
            WHERE s.deleted=0 AND s.projection_blocked=0 AND s.generation=w.generation AND w.configuration_hash=?
              AND w.state!='complete' AND c.retention!='present' AND (? IS NULL OR s.id=?)
              AND c.start_frame < w.context_end
              AND c.end_frame > w.context_start
            LIMIT 1
            """, [.text(configurationFingerprint), filter, filter])
        let completedEpochHasGap = try !database.rows("""
            SELECT 1 FROM epochs e
            JOIN sessions s ON s.id=e.session_id
            LEFT JOIN analysis_epochs a ON a.epoch_id=e.id AND a.configuration_hash=?
            LEFT JOIN epoch_closures ec ON ec.epoch_id=e.id
            WHERE s.deleted=0 AND s.projection_blocked=0 AND a.epoch_id IS NOT NULL AND a.has_pending=0
              AND (? IS NULL OR s.id=?)
              AND COALESCE((SELECT SUM(c.end_frame - c.start_frame) FROM chunks c WHERE c.epoch_id=e.id), 0)
                  < MAX(e.max_received_end_frame, COALESCE(ec.end_frame, 0))
            LIMIT 1
            """, [.text(configurationFingerprint), filter, filter]).isEmpty
        var context = false, queued = false, missing = completedEpochHasGap
        var unavailable = !unavailableFailures.isEmpty || !unavailableWindows.isEmpty
        for row in try database.rows("""
            SELECT e.id,s.generation,a.checkpoint
            FROM epochs e JOIN sessions s ON s.id=e.session_id
            LEFT JOIN analysis_epochs a ON a.epoch_id=e.id AND a.configuration_hash=?
            WHERE s.deleted=0 AND s.projection_blocked=0 AND (a.epoch_id IS NULL OR a.has_pending!=0) AND (? IS NULL OR s.id=?)
            """, [.text(configurationFingerprint), filter, filter]) {
            let id = try row.requireUUID(0)
            let generation = try row.requireInt(1)
            let checkpointStart = (row.data(2).flatMap { try? WireJSON.decode(ArchiveCheckpoint.self, from: $0) })?.sourceFrame ?? 0
            let received = try receivedAnalysisRanges(epochID: id, retainedOnly: false)
            let retained = try receivedAnalysisRanges(epochID: id, retainedOnly: true)
            let end = max(received.last?.end ?? 0, try analysisClosedFrame(epochID: id) ?? 0)
            let gaps = end > 0 ? try CoverageRanges.subtract([FrameRange(start: 0, count: end)], received) : []
            missing = missing || !gaps.isEmpty
            let epochUnavailableRanges = try database.rows("""
                SELECT start_frame,end_frame FROM processing_failures
                WHERE epoch_id=? AND generation=? AND configuration_hash=? AND stage='analysis' AND error_code='audio_unavailable'
                """, [.text(id.uuidString), .integer(generation), .text(configurationFingerprint)]).map {
                    try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
                }
            for range in try pendingAnalysisRanges(epochID: id, fingerprint: configurationFingerprint, retainedOnly: false) {
                if !(try CoverageRanges.subtract([range], retained)).isEmpty
                    || epochUnavailableRanges.contains(where: { $0.start < range.end && $0.end > range.start }) {
                    unavailable = true
                    continue
                }
                if gaps.contains(where: { $0.start <= checkpointStart && $0.end > checkpointStart && $0.start < range.start }) {
                    continue
                }
                let examined = try database.rows("SELECT 1 FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=? AND generation=? AND start_frame>=? AND start_frame<? LIMIT 1",
                    [.text(id.uuidString), .text(configurationFingerprint), .integer(generation), .integer(range.start), .integer(range.end)])
                context = context || !examined.isEmpty
                queued = queued || examined.isEmpty
            }
        }
        if !queued {
            let pendingWindows = try database.rows("""
                SELECT w.epoch_id,w.analysis_anchor,w.context_end
                FROM analysis_windows w JOIN sessions s ON s.id=w.session_id
                WHERE s.deleted=0 AND s.projection_blocked=0 AND s.generation=w.generation AND w.configuration_hash=?
                  AND w.state!='complete' AND (? IS NULL OR s.id=?)
                  AND NOT EXISTS (
                      SELECT 1 FROM processing_failures f
                      WHERE f.epoch_id=w.epoch_id AND f.generation=w.generation
                        AND f.configuration_hash=w.configuration_hash
                        AND f.stage='transcription' AND f.work_id=w.id
                        AND (f.error_code='audio_unavailable' OR f.retry_after>?)
                  )
                LIMIT 32
                """, [.text(configurationFingerprint), filter, filter, .double(nowSeconds)])
            for wRow in pendingWindows {
                let epID = try wRow.requireUUID(0)
                let anchor = try wRow.requireInt(1), ctxEnd = try wRow.requireInt(2)
                let inputs = try contiguousInputs(epochID: epID, from: anchor, through: ctxEnd)
                if (inputs.last?.envelope.manifest.frames.end ?? -1) >= ctxEnd {
                    queued = true
                    break
                }
            }
        }
        if queued { return .queued }
        if context { return .awaitingContext }
        if unavailable { return .unavailableAudio }
        if missing { return .awaitingAudio }
        return .idle
    }
}
