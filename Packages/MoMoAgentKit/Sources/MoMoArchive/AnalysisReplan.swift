import Foundation
import MoMoContracts

extension ArchiveStore {
    static let analysisReplanPrefix = "analysis-replan/"
    static let analysisReplanRepairKey = "analysis-replan-repair/v1/"

    /// Records that a session must be analyzed again from its audio. The archive does not know the
    /// active speech configuration, so the work runs later in `replanRequestedAnalysis`.
    func requestAnalysisReplan(sessionID: UUID) throws {
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES(?,'1')",
            [.text(Self.analysisReplanPrefix + sessionID.uuidString)])
    }

    /// Runs requested re-plans for the active configuration, after completed history has been
    /// preserved for it. Windows are dropped and re-planned rather than reset in place: a window
    /// carried forward by `preserveCompletedAnalysis` has an ID the planner cannot rebuild, so a
    /// pending carried window could never be transcribed again. Other configurations keep their
    /// completed windows as provenance. Returns the number of sessions re-planned.
    @discardableResult
    public func replanRequestedAnalysis(configurationFingerprint: String) throws -> Int {
        guard ContentHash.isValid(configurationFingerprint) else { throw ArchiveError.invalidQuery }
        return try database.transaction {
            try repairStrandedAnalysisOnce(configurationFingerprint: configurationFingerprint)
            var replanned = 0
            for row in try database.rows("SELECT key FROM metadata WHERE key LIKE ? ORDER BY key",
                                         [.text(Self.analysisReplanPrefix + "%")]) {
                let key = try row.requireString(0)
                guard let sessionID = UUID(uuidString: String(key.dropFirst(Self.analysisReplanPrefix.count))) else {
                    try database.execute("DELETE FROM metadata WHERE key=?", [.text(key)])
                    continue
                }
                switch try replanAnalysis(sessionID: sessionID, configurationFingerprint: configurationFingerprint) {
                case .replanned:
                    replanned += 1
                    try database.execute("DELETE FROM metadata WHERE key=?", [.text(key)])
                case .gone:
                    try database.execute("DELETE FROM metadata WHERE key=?", [.text(key)])
                case .busy:
                    continue
                }
            }
            return replanned
        }
    }

    private enum ReplanOutcome { case replanned, busy, gone }

    private func replanAnalysis(sessionID: UUID, configurationFingerprint: String) throws -> ReplanOutcome {
        let sid = SQLValue.text(sessionID.uuidString)
        guard let session = try database.rows("SELECT deleted,generation FROM sessions WHERE id=?", [sid]).first,
              session.integer(0) == 0 else { return .gone }
        let generation = try session.requireInt(1)
        // Same eligibility as the speaker requeue: never pull work out from under an attempt or batch.
        guard try database.rows("SELECT 1 FROM analysis_windows WHERE session_id=? AND state='running' LIMIT 1", [sid]).isEmpty,
              try database.rows("""
                SELECT 1 FROM analysis_epochs a JOIN epochs e ON e.id=a.epoch_id
                WHERE e.session_id=? AND a.attempt_id IS NOT NULL LIMIT 1
                """, [sid]).isEmpty,
              try !batchReservesSession(sessionID) else { return .busy }

        if let old = try currentTranscriptOrNil(sessionID: sessionID), !old.spans.isEmpty {
            try storeDocument(
                TranscriptDocument(sessionID: sessionID, version: old.version + 1, generation: old.generation,
                                   spans: [], updatedAt: Date()),
                invalidatesExistingSources: true)
        }
        for epoch in try database.rows("SELECT id FROM epochs WHERE session_id=?", [sid]) {
            let epochID = try epoch.requireString(0)
            let current: [SQLValue] = [.text(epochID), .text(configurationFingerprint)]
            try database.execute("DELETE FROM analysis_windows WHERE epoch_id=? AND configuration_hash=?", current)
            try database.execute("DELETE FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=?", current)
            try database.execute("DELETE FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=?", current)
            // Keep the row so a later preserveCompletedAnalysis treats the epoch as owned by this
            // configuration and does not carry older results back in.
            try database.execute("""
                INSERT INTO analysis_epochs(epoch_id,configuration_hash,generation,attempt_id,last_input_hash,checkpoint,has_pending)
                VALUES(?,?,?,NULL,NULL,NULL,1)
                ON CONFLICT(epoch_id,configuration_hash) DO UPDATE SET
                    generation=excluded.generation,attempt_id=NULL,last_input_hash=NULL,checkpoint=NULL,has_pending=1
                """, current + [.integer(generation)])
            // An older configuration with no completed result left is not history any more, only
            // work no engine claims. Drop it so it cannot hold the recording as pending.
            for other in try database.rows("""
                SELECT DISTINCT w.configuration_hash FROM analysis_windows w
                WHERE w.epoch_id=? AND w.configuration_hash!=?
                  AND NOT EXISTS (SELECT 1 FROM analysis_windows c WHERE c.epoch_id=w.epoch_id
                      AND c.configuration_hash=w.configuration_hash AND c.state='complete')
                """, current) {
                try dropAnalysis(epochID: epochID, configurationFingerprint: try other.requireString(0))
            }
        }
        try database.execute("""
            UPDATE transcription_jobs SET state='pending',attempt_id=NULL,error_code=NULL
            WHERE chunk_id IN (SELECT id FROM chunks WHERE session_id=?) AND state='complete'
            """, [sid])
        try database.execute("DELETE FROM processing_failures WHERE session_id=?", [sid])
        return .replanned
    }

    /// Repairs archives where an earlier speaker requeue reset every complete window to pending in
    /// place, whatever its configuration. Two kinds of stranded work are left behind:
    /// - pending carried windows of the active configuration, which fail `incompatible_window` on
    ///   every attempt; their sessions are re-planned like a requeue;
    /// - pending windows of older configurations with no completed result left, which no engine
    ///   claims; that analysis state is dropped. Its results were already discarded by the reset,
    ///   and restoring the windows as complete without results would let a later upgrade carry
    ///   empty results forward as analyzed audio.
    private func repairStrandedAnalysisOnce(configurationFingerprint: String) throws {
        let marker = Self.analysisReplanRepairKey + configurationFingerprint
        guard try database.rows("SELECT 1 FROM metadata WHERE key=?", [.text(marker)]).isEmpty else { return }
        var sessions: Set<UUID> = []
        for epoch in try database.rows("""
            SELECT DISTINCT w.epoch_id,w.session_id FROM analysis_windows w JOIN sessions s ON s.id=w.session_id
            WHERE s.deleted=0 AND w.configuration_hash=? AND w.state='pending'
            """, [.text(configurationFingerprint)]) {
            let epochID = try epoch.requireString(0)
            let pending = try Set(database.rows("""
                SELECT id FROM analysis_windows WHERE epoch_id=? AND configuration_hash=? AND state='pending'
                """, [.text(epochID), .text(configurationFingerprint)]).map { try $0.requireString(0) })
            // Detect carried copies before dropping the older windows they were copied from.
            let sources = try database.rows("""
                SELECT id FROM analysis_windows WHERE epoch_id=? AND configuration_hash!=?
                """, [.text(epochID), .text(configurationFingerprint)]).map { try $0.requireString(0) }
            if sources.contains(where: {
                pending.contains(ContentHash.sha256(Data("carry/\($0)/\(configurationFingerprint)".utf8)))
            }) { sessions.insert(try epoch.requireUUID(1)) }
        }
        for row in try database.rows("""
            SELECT DISTINCT w.epoch_id,w.configuration_hash FROM analysis_windows w
            WHERE w.configuration_hash!=? AND w.state='pending'
              AND NOT EXISTS (SELECT 1 FROM analysis_windows c WHERE c.epoch_id=w.epoch_id
                  AND c.configuration_hash=w.configuration_hash AND c.state='complete')
            """, [.text(configurationFingerprint)]) {
            try dropAnalysis(epochID: try row.requireString(0), configurationFingerprint: try row.requireString(1))
        }
        // The repair requests the re-plan; `replanRequestedAnalysis` runs it now or, for a busy
        // session, on a later call. The carry sources may already be gone by then.
        for sessionID in sessions { try requestAnalysisReplan(sessionID: sessionID) }
        try database.execute("INSERT OR IGNORE INTO metadata(key,value) VALUES(?,'1')", [.text(marker)])
    }

    private func dropAnalysis(epochID: String, configurationFingerprint: String) throws {
        let key: [SQLValue] = [.text(epochID), .text(configurationFingerprint)]
        try database.execute("DELETE FROM analysis_windows WHERE epoch_id=? AND configuration_hash=?", key)
        try database.execute("DELETE FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=?", key)
        try database.execute("DELETE FROM analysis_range_inputs WHERE epoch_id=? AND configuration_hash=?", key)
        try database.execute("DELETE FROM analysis_epochs WHERE epoch_id=? AND configuration_hash=?", key)
    }
}
