import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Preserve completed history on a detector/policy upgrade. Never enqueue previously skipped audio.
    /// Original descriptors/results remain under their original fingerprint for provenance.
    public func preserveCompletedAnalysis(from previous: String, to current: String) throws {
        guard ContentHash.isValid(previous), ContentHash.isValid(current), previous != current else {
            throw ArchiveError.invalidQuery
        }
        let marker = "analysis-upgrade/\(previous)/\(current)"
        guard try database.rows("SELECT 1 FROM metadata WHERE key=?", [.text(marker)]).isEmpty else { return }
        try database.transaction {
            var existingEpochs: Set<UUID> = []
            let epochs = try database.rows("""
                SELECT e.id,e.session_id,s.generation FROM epochs e JOIN sessions s ON s.id=e.session_id
                JOIN analysis_epochs a ON a.epoch_id=e.id AND a.configuration_hash=?
                WHERE s.deleted=0
                """, [.text(previous)])
            for row in epochs {
                let epoch = try row.requireUUID(0), session = try row.requireUUID(1), generation = try row.requireInt(2)
                let key: [SQLValue] = [.text(epoch.uuidString), .text(current)]
                // A resumed upgrade must not replace work already committed by the new version.
                guard try database.rows("SELECT 1 FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?", key).isEmpty else {
                    existingEpochs.insert(epoch)
                    continue
                }
                var preserved: [FrameRange] = []
                let completed = try database.rows("""
                    SELECT descriptor,raw_result FROM analysis_windows
                    WHERE epoch_id=? AND configuration_hash=? AND state='complete'
                    """, [.text(epoch.uuidString), .text(previous)])
                for item in completed {
                    let old = try WireJSON.decode(ArchiveAnalysisWindow.self, from: item.requireData(0))
                    let id = ContentHash.sha256(Data("carry/\(old.id)/\(current)".utf8))
                    let window = ArchiveAnalysisWindow(id: id, sessionID: session, epochID: epoch,
                        analysisAnchor: old.analysisAnchor, coreFrames: old.coreFrames, contextFrames: old.contextFrames,
                        modelCoreFrames: old.modelCoreFrames, modelContextFrames: old.modelContextFrames,
                        sources: old.sources, replayInputManifestHashes: old.replayInputManifestHashes,
                        configurationFingerprint: current)
                    try database.execute("""
                        INSERT INTO analysis_windows(id,epoch_id,session_id,generation,configuration_hash,descriptor,state,raw_result)
                        VALUES(?,?,?,?,?,?,'complete',?)
                        """, [.text(id), .text(epoch.uuidString), .text(session.uuidString), .integer(generation),
                              .text(current), .blob(try WireJSON.encode(window)), item.data(1).map(SQLValue.blob) ?? .null])
                    preserved.append(old.coreFrames)
                }
                for item in try database.rows("""
                    SELECT start_frame,end_frame FROM analysis_coverage
                    WHERE epoch_id=? AND configuration_hash=? AND kind='no_speech'
                    """, [.text(epoch.uuidString), .text(previous)]) {
                    let range = try FrameRange(start: item.requireInt(0), count: item.requireInt(1) - item.requireInt(0))
                    preserved.append(range)
                    try database.execute("""
                        INSERT OR IGNORE INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind)
                        VALUES(?,?,?,?,'no_speech')
                        """, key + [.integer(range.start), .integer(range.end)])
                }
                let ranges = try CoverageRanges.union(preserved)
                for range in ranges {
                    try database.execute("""
                        INSERT INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind)
                        VALUES(?,?,?,?,'analyzed')
                        """, key + [.integer(range.start), .integer(range.end)])
                }
                let floor = ranges.first?.start == 0 ? ranges.first!.end : 0
                let checkpoint: SQLValue = floor == 0 ? .null : .blob(try WireJSON.encode(ArchiveCheckpoint(
                    sessionID: session, epochID: epoch, sourceFrame: floor, configurationFingerprint: current)))
                let pending = try !pendingAnalysisRanges(epochID: epoch, fingerprint: current, retainedOnly: true).isEmpty
                try database.execute("""
                    INSERT INTO analysis_epochs(epoch_id,configuration_hash,generation,checkpoint,has_pending)
                    VALUES(?,?,?,?,?)
                    """, key + [.integer(generation), checkpoint, .integer(pending ? 1 : 0)])
            }
            try upgradeUnfinishedBatches(from: previous, to: current, existingEpochs: existingEpochs)
            try database.execute("INSERT INTO metadata(key,value) VALUES(?,'1')", [.text(marker)])
        }
    }

    private func upgradeUnfinishedBatches(from previous: String, to current: String, existingEpochs: Set<UUID>) throws {
        for batch in try database.rows("SELECT id FROM transcription_batches WHERE configuration_hash=? AND state!='completed'", [.text(previous)]) {
            let id = try batch.requireString(0)
            let batchUUID = try batch.requireUUID(0)
            if !existingEpochs.isEmpty {
                for row in try database.rows("SELECT DISTINCT epoch_id,session_id,timebase FROM transcription_batch_ranges WHERE batch_id=?", [.text(id)]) {
                    let epochID = try row.requireUUID(0)
                    guard existingEpochs.contains(epochID) else { continue }
                    let sessionID = try row.requireString(1)
                    guard let rate = row.double(2) else { throw ArchiveError.database(11) }
                    let parts = try database.rows("SELECT start_frame,end_frame FROM transcription_batch_ranges WHERE batch_id=? AND epoch_id=?",
                        [.text(id), .text(epochID.uuidString)]).map {
                            try FrameRange(start: $0.requireInt(0), count: $0.requireInt(1) - $0.requireInt(0))
                        }
                    let frozen = try FrameRange.union(parts)
                    try database.execute("DELETE FROM transcription_batch_ranges WHERE batch_id=? AND epoch_id=?", [.text(id), .text(epochID.uuidString)])
                    try database.execute("DELETE FROM transcription_batch_windows WHERE batch_id=? AND epoch_id=?", [.text(id), .text(epochID.uuidString)])
                    for range in frozen {
                        try database.execute("""
                            INSERT OR IGNORE INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind)
                            VALUES(?,?,?,?,?,?,'unprepared')
                            """, [.text(id), .text(sessionID), .text(epochID.uuidString), .double(rate), .integer(range.start), .integer(range.end)])
                    }
                }
            }
            for member in try database.rows("""
                SELECT m.window_id,m.session_id,m.epoch_id,m.start_frame,m.end_frame,e.timebase
                FROM transcription_batch_windows m JOIN epochs e ON e.id=m.epoch_id WHERE m.batch_id=?
                """, [.text(id)]) {
                let oldID = try member.requireString(0)
                let carried = ContentHash.sha256(Data("carry/\(oldID)/\(current)".utf8))
                if try !database.rows("SELECT 1 FROM analysis_windows WHERE id=?", [.text(carried)]).isEmpty {
                    try database.execute("UPDATE transcription_batch_windows SET window_id=? WHERE batch_id=? AND window_id=?",
                        [.text(carried), .text(id), .text(oldID)])
                } else {
                    // Only work that never completed returns to preparation. Completed history is untouched.
                    guard let rate = member.double(5) else { throw ArchiveError.database(11) }
                    try database.execute("""
                        INSERT OR IGNORE INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind)
                        VALUES(?,?,?,?,?,?,'unprepared')
                        """, [.text(id), .text(try member.requireString(1)), .text(try member.requireString(2)),
                              .double(rate), .integer(try member.requireInt(3)), .integer(try member.requireInt(4))])
                    try database.execute("DELETE FROM transcription_batch_windows WHERE batch_id=? AND window_id=?", [.text(id), .text(oldID)])
                }
            }
            try registerOverlappingBatchWindows(batchID: batchUUID, fingerprint: current)
            try database.execute("UPDATE transcription_batch_executions SET end_reason='interrupted' WHERE batch_id=? AND end_reason IS NULL", [.text(id)])
            try database.execute("""
                UPDATE transcription_batches SET configuration_hash=?,current_execution=NULL,end_reason='interrupted',
                state=CASE WHEN state='paused' THEN 'paused' ELSE 'ready' END WHERE id=?
                """, [.text(current), .text(id)])
        }
    }
}
