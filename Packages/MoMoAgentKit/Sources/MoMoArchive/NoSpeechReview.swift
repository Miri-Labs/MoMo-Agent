import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Reopens previously skipped no-speech intervals while preserving existing text and windows.
    public func reopenNoSpeechOnce(key: String, in interval: DateInterval, configurationFingerprint: String) throws -> TimeInterval {
        guard !key.isEmpty else { throw ArchiveError.invalidQuery }
        guard try database.rows("SELECT 1 FROM metadata WHERE key=?", [.text(key)]).isEmpty else { return 0 }
        do {
            let seconds = try reopenNoSpeech(in: interval, configurationFingerprint: configurationFingerprint)
            try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES(?,'1')", [.text(key)])
            return seconds
        } catch ArchiveError.staleAttempt {
            return 0
        }
    }

    public func reopenNoSpeech(in interval: DateInterval, configurationFingerprint: String) throws -> TimeInterval {
        guard ContentHash.isValid(configurationFingerprint), interval.start.timeIntervalSince1970.isFinite,
              interval.end.timeIntervalSince1970.isFinite, interval.duration > 0 else { throw ArchiveError.invalidQuery }
        return try database.transaction {
            var seconds: TimeInterval = 0
            let epochs = try database.rows("""
                SELECT e.id,e.session_id,s.generation,c.manifest,a.attempt_id
                FROM epochs e JOIN sessions s ON s.id=e.session_id
                JOIN chunks c ON c.rowid=(SELECT MIN(rowid) FROM chunks WHERE epoch_id=e.id)
                JOIN analysis_epochs a ON a.epoch_id=e.id AND a.configuration_hash=?
                WHERE s.deleted=0 AND s.projection_blocked=0 AND a.generation=s.generation
                """, [.text(configurationFingerprint)])
            for row in epochs {
                let epochID = try row.requireUUID(0)
                let manifest = try WireJSON.decode(ChunkManifest.self, from: row.requireData(3))
                let retained = try receivedAnalysisRanges(epochID: epochID, retainedOnly: true)
                guard let first = retained.first, let last = retained.last else { continue }
                // Clamp dates before conversion, including sessions that span midnight.
                let lower = max(Double(first.start),
                    interval.start.timeIntervalSince(manifest.wallClockAnchor) * manifest.timebaseHz)
                let upper = min(Double(last.end),
                    interval.end.timeIntervalSince(manifest.wallClockAnchor) * manifest.timebaseHz)
                guard lower.isFinite, upper.isFinite, upper > lower else { continue }
                let start = Int64(lower.rounded(.up)), end = Int64(upper.rounded(.down))
                guard end > start else { continue }
                let scope = try FrameRange(start: start, count: end - start)
                let key: [SQLValue] = [.text(epochID.uuidString), .text(configurationFingerprint)]
                let rows = try database.rows("""
                    SELECT rowid,start_frame,end_frame,kind FROM analysis_coverage
                    WHERE epoch_id=? AND configuration_hash=? AND end_frame>? AND start_frame<?
                    """, key + [.integer(start), .integer(end)])
                let silence = try rows.filter { $0.string(3) == "no_speech" }.map {
                    try FrameRange(start: max(start, $0.requireInt(1)),
                                   count: min(end, $0.requireInt(2)) - max(start, $0.requireInt(1)))
                }
                // A repeated review must also exclude any text discovered by the previous review.
                let windows = try database.rows("SELECT descriptor FROM analysis_windows WHERE epoch_id=?",
                    [.text(epochID.uuidString)]).map {
                    try WireJSON.decode(ArchiveAnalysisWindow.self, from: $0.requireData(0)).coreFrames
                }
                let chunkIDs = try Set(database.rows("SELECT id FROM chunks WHERE epoch_id=?", [.text(epochID.uuidString)])
                    .map { try $0.requireUUID(0) })
                let existingText = try currentTranscriptOrNil(sessionID: row.requireUUID(1))?.spans
                    .filter { chunkIDs.contains($0.chunkID) }.map(\.frames) ?? []
                let unavailable = try CoverageRanges.subtract([scope], retained)
                let review = try CoverageRanges.subtract(CoverageRanges.union(silence), windows + existingText + unavailable)
                guard !review.isEmpty else { continue }
                guard row.string(4) == nil else { throw ArchiveError.staleAttempt }
                for coverage in rows {
                    let original = try FrameRange(start: coverage.requireInt(1),
                        count: coverage.requireInt(2) - coverage.requireInt(1))
                    let remaining = try CoverageRanges.subtract([original], review)
                    guard remaining != [original] else { continue }
                    try database.execute("DELETE FROM analysis_coverage WHERE rowid=?", [.integer(try coverage.requireInt(0))])
                    for range in remaining {
                        try database.execute("""
                            INSERT OR IGNORE INTO analysis_coverage(epoch_id,configuration_hash,start_frame,end_frame,kind)
                            VALUES(?,?,?,?,?)
                            """, key + [.integer(range.start), .integer(range.end), .text(try coverage.requireString(3))])
                    }
                }
                let prefix = try analyzedRanges(epochID: epochID, fingerprint: configurationFingerprint).first
                let floor = prefix?.start == 0 ? prefix?.end ?? 0 : 0
                let checkpoint: SQLValue = floor > 0 ? .blob(try WireJSON.encode(ArchiveCheckpoint(
                    sessionID: row.requireUUID(1), epochID: epochID, sourceFrame: floor,
                    configurationFingerprint: configurationFingerprint))) : .null
                try database.execute("""
                    UPDATE analysis_epochs SET checkpoint=?,last_input_hash=NULL,has_pending=1
                    WHERE epoch_id=? AND configuration_hash=?
                    """, [checkpoint] + key)
                try database.execute("DELETE FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=?", key)
                seconds += review.reduce(0) { $0 + Double($1.count) / manifest.timebaseHz }
            }
            return seconds
        }
    }
}
