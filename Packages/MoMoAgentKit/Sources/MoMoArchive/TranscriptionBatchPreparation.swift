import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Snapshot only locally retained, unanalyzed frames. New receipts never extend this batch.
    func unpreparedBatchRanges(fingerprint: String) throws -> [(sessionID: UUID, epochID: UUID, timebaseHz: Double, frames: FrameRange)] {
        var sources: [(sessionID: UUID, epochID: UUID, timebaseHz: Double, frames: FrameRange)] = []
        for row in try database.rows("""
            SELECT e.id,e.session_id,e.timebase FROM epochs e
            JOIN sessions s ON s.id=e.session_id WHERE s.deleted=0 ORDER BY s.recorded_at,e.rowid
            """) {
            let epochID = try row.requireUUID(0)
            guard try !batchReservesAnalysis(epochID: epochID) else { continue }
            guard let rate = row.double(2), rate.isFinite, rate > 0 else { throw ArchiveError.invalidTranscript }
            for frames in try pendingAnalysisRanges(epochID: epochID, fingerprint: fingerprint, retainedOnly: true) {
                sources.append((sessionID: try row.requireUUID(1), epochID: epochID, timebaseHz: rate, frames: frames))
            }
        }
        return sources
    }

    // A paused batch owns preparation too; another scheduler must not analyze beyond its snapshot.
    func batchReservesAnalysis(epochID: UUID, except batchID: UUID? = nil) throws -> Bool {
        try database.rows("""
            SELECT DISTINCT r.batch_id FROM transcription_batch_ranges r
            JOIN transcription_batches b ON b.id=r.batch_id
            WHERE r.epoch_id=? AND r.kind='unprepared' AND b.state!='completed'
            """, [.text(epochID.uuidString)]).contains { try $0.requireUUID(0) != batchID }
    }

    /// Registers windows produced after admission, preserving the original progress denominator.
    func registerPreparedBatchWindows(execution: TranscriptionBatchExecution, fingerprint: String) throws {
        try validateBatchExecution(execution, fingerprint: fingerprint)
        try registerOverlappingBatchWindows(batchID: execution.batchID, fingerprint: fingerprint)
    }

    func registerOverlappingBatchWindows(batchID: UUID, fingerprint: String) throws {
        for row in try database.rows("""
            SELECT w.descriptor,w.state FROM analysis_windows w JOIN sessions s ON s.id=w.session_id
            WHERE w.configuration_hash=? AND w.generation=s.generation AND s.deleted=0 AND w.state IN ('pending','running','complete')
              AND NOT EXISTS(SELECT 1 FROM transcription_batch_windows m WHERE m.batch_id=? AND m.window_id=w.id)
              AND EXISTS(SELECT 1 FROM transcription_batch_ranges r WHERE r.batch_id=? AND r.epoch_id=w.epoch_id AND r.kind='unprepared')
            """, [.text(fingerprint), .text(batchID.uuidString), .text(batchID.uuidString)]) {
            let window = try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(0))
            let ranges = try batchPreparationRanges(id: batchID, epochID: window.epochID)
            guard try !CoverageRanges.intersection([window.coreFrames], ranges).isEmpty else { continue }
            if row.string(1) != "complete", try batchReserves(window, except: batchID) { continue }
            try database.execute("INSERT OR IGNORE INTO transcription_batch_windows(batch_id,window_id,session_id,epoch_id,start_frame,end_frame) VALUES(?,?,?,?,?,?)", [
                .text(batchID.uuidString), .text(window.id), .text(window.sessionID.uuidString),
                .text(window.epochID.uuidString), .integer(window.coreFrames.start), .integer(window.coreFrames.end)
            ])
        }
    }

    public func claimTranscriptionBatchAnalysis(execution: TranscriptionBatchExecution,
                                                configurationFingerprint: String) throws -> EpochAnalysisTicket? {
        try validateBatchExecution(execution, fingerprint: configurationFingerprint)
        for row in try database.rows("""
            SELECT DISTINCT r.epoch_id,r.session_id,s.generation FROM transcription_batch_ranges r
            JOIN sessions s ON s.id=r.session_id WHERE r.batch_id=? AND r.kind='unprepared' AND s.deleted=0
            ORDER BY s.recorded_at,r.epoch_id
            """, [.text(execution.batchID.uuidString)]) {
            let epochID = try row.requireUUID(0)
            let pending = try CoverageRanges.subtract(batchPreparationRanges(id: execution.batchID, epochID: epochID),
                analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint))
            for range in pending {
                if let ticket = try claimEpochAnalysis(configurationFingerprint: configurationFingerprint,
                    sessionID: row.requireUUID(1), expectedGeneration: row.requireInt(2),
                    finalizeAvailablePrefixBefore: .distantFuture, selectedEpochID: epochID,
                    processingRange: range, batchExecution: execution) {
                    return ticket
                }
            }
        }
        return nil
    }

    func batchPreparationRanges(id: UUID, epochID: UUID) throws -> [FrameRange] {
        try database.rows("SELECT start_frame,end_frame FROM transcription_batch_ranges WHERE batch_id=? AND epoch_id=? AND kind='unprepared'",
            [.text(id.uuidString), .text(epochID.uuidString)]).map {
                try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
            }
    }
}
