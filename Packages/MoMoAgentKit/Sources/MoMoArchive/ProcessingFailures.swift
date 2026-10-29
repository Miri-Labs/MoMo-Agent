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
                try saveProcessingFailure(sessionID: ticket.sessionID, epochID: ticket.epochID, generation: ticket.expectedGeneration,
                    fingerprint: ticket.configurationFingerprint, stage: .analysis, workID: ticket.inputIdentity,
                    frames: analysisInputRange(ticket.inputs, start: ticket.checkpoint?.sourceFrame, end: ticket.boundary.endFrame), code: code, now: now)
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
        let deferred = try database.rows("SELECT MIN(f.retry_after) FROM processing_failures f JOIN sessions s ON s.id=f.session_id WHERE s.deleted=0 AND s.generation=f.generation AND f.configuration_hash=? AND f.error_code!='audio_unavailable' AND f.retry_after>? AND (? IS NULL OR s.id=?)",
            [.text(configurationFingerprint), .double(Date().timeIntervalSince1970), filter, filter]).first?.double(0)
        if let deferred { return .retryScheduled(Date(timeIntervalSince1970: deferred)) }
        let unavailableFailures = try database.rows("SELECT 1 FROM processing_failures f JOIN sessions s ON s.id=f.session_id WHERE s.deleted=0 AND s.generation=f.generation AND f.configuration_hash=? AND f.error_code='audio_unavailable' AND (? IS NULL OR s.id=?) LIMIT 1",
            [.text(configurationFingerprint), filter, filter])
        // Analysis can already be complete when a pending ASR window loses its
        // audio. Its missing context must not be hidden by an open recording tail.
        let unavailableWindows = try database.rows("""
            SELECT 1 FROM analysis_windows w JOIN sessions s ON s.id=w.session_id
            JOIN chunks c ON c.epoch_id=w.epoch_id
            WHERE s.deleted=0 AND s.generation=w.generation AND w.configuration_hash=?
              AND w.state!='complete' AND c.retention!='present' AND (? IS NULL OR s.id=?)
              AND json_extract(CAST(c.manifest AS TEXT),'$.frames.start')
                < json_extract(CAST(w.descriptor AS TEXT),'$.contextFrames.start')
                  + json_extract(CAST(w.descriptor AS TEXT),'$.contextFrames.count')
              AND json_extract(CAST(c.manifest AS TEXT),'$.frames.start')
                + json_extract(CAST(c.manifest AS TEXT),'$.frames.count')
                > json_extract(CAST(w.descriptor AS TEXT),'$.contextFrames.start')
            LIMIT 1
            """, [.text(configurationFingerprint), filter, filter])
        var context = false, queued = false, missing = false
        var unavailable = !unavailableFailures.isEmpty || !unavailableWindows.isEmpty
        for row in try database.rows("SELECT e.id,s.generation FROM epochs e JOIN sessions s ON s.id=e.session_id WHERE s.deleted=0 AND (? IS NULL OR s.id=?)", [filter, filter]) {
            let id = try row.requireUUID(0)
            let received = try receivedAnalysisRanges(epochID: id, retainedOnly: false)
            let retained = try receivedAnalysisRanges(epochID: id, retainedOnly: true)
            let end = max(received.last?.end ?? 0, try analysisClosedFrame(epochID: id) ?? 0)
            if end > 0 {
                let gaps = try CoverageRanges.subtract([FrameRange(start: 0, count: end)], received)
                missing = missing || !gaps.isEmpty
            }
            for range in try pendingAnalysisRanges(epochID: id, fingerprint: configurationFingerprint, retainedOnly: false) {
                if !(try CoverageRanges.subtract([range], retained)).isEmpty { unavailable = true; continue }
                let examined = try database.rows("SELECT 1 FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=? AND generation=? AND start_frame>=? AND start_frame<? LIMIT 1",
                    [.text(id.uuidString), .text(configurationFingerprint), .integer(try row.requireInt(1)), .integer(range.start), .integer(range.end)])
                context = context || !examined.isEmpty
                queued = queued || examined.isEmpty
            }
        }
        if unavailable { return .unavailableAudio }
        if missing { return .awaitingAudio }
        if queued { return .queued }
        if context { return .awaitingContext }
        let pending = try database.rows("SELECT 1 FROM analysis_windows w JOIN sessions s ON s.id=w.session_id WHERE s.deleted=0 AND s.generation=w.generation AND w.configuration_hash=? AND w.state!='complete' AND (? IS NULL OR s.id=?) LIMIT 1", [.text(configurationFingerprint), filter, filter])
        return pending.isEmpty ? .idle : .queued
    }
}
