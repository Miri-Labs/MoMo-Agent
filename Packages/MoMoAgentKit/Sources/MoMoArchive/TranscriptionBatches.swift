import Foundation
import MoMoContracts

extension ArchiveStore {
    /// Freezes available work. Optional raw ranges use received-snapshot boundaries, never a capture end.
    public func freezeTranscriptionBatch(id: UUID = UUID(), configurationFingerprint: String,
                                         includingUnpreparedAudio: Bool = false) throws -> TranscriptionBatch? {
        guard ContentHash.isValid(configurationFingerprint) else { throw ArchiveError.invalidQuery }
        return try database.transaction {
            if try !database.rows("SELECT 1 FROM transcription_batches WHERE id=?", [.text(id.uuidString)]).isEmpty {
                let existing = try transcriptionBatch(id: id)
                guard existing.configurationFingerprint == configurationFingerprint else { throw TranscriptionBatchError.configurationMismatch }
                return existing
            }
            let rows = try database.rows("SELECT w.descriptor FROM analysis_windows w JOIN sessions s ON s.id=w.session_id WHERE w.state='pending' AND w.configuration_hash=? AND w.generation=s.generation AND s.deleted=0 AND NOT EXISTS (SELECT 1 FROM transcription_jobs j JOIN chunks c ON c.id=j.chunk_id WHERE c.session_id=s.id AND j.state='running') ORDER BY w.rowid", [.text(configurationFingerprint)])
            let windows = try rows.map { try WireJSON.decode(ArchiveAnalysisWindow.self, from: $0.requireData(0)) }
                .filter { try !batchReserves($0) }
            let unprepared = includingUnpreparedAudio ? try unpreparedBatchRanges(fingerprint: configurationFingerprint) : []
            guard !windows.isEmpty || !unprepared.isEmpty else { return nil }
            try database.execute("INSERT INTO transcription_batches(id,configuration_hash) VALUES(?,?)", [.text(id.uuidString), .text(configurationFingerprint)])
            for source in unprepared {
                try database.execute("INSERT INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind) VALUES(?,?,?,?,?,?,'unprepared')", [
                    .text(id.uuidString), .text(source.sessionID.uuidString), .text(source.epochID.uuidString),
                    .double(source.timebaseHz), .integer(source.frames.start), .integer(source.frames.end)
                ])
            }
            for window in windows {
                try database.execute("INSERT INTO transcription_batch_windows(batch_id,window_id,session_id,epoch_id,start_frame,end_frame) VALUES(?,?,?,?,?,?)", [
                    .text(id.uuidString), .text(window.id), .text(window.sessionID.uuidString), .text(window.epochID.uuidString),
                    .integer(window.coreFrames.start), .integer(window.coreFrames.end)
                ])
            }
            let byEpoch = Dictionary(grouping: windows, by: \.epochID)
            let epochs = try database.rows("SELECT e.id,e.session_id,e.timebase FROM epochs e JOIN sessions s ON s.id=e.session_id WHERE s.deleted=0 ORDER BY e.rowid")
            for epoch in epochs {
                let epochID = try epoch.requireUUID(0), sessionID = try epoch.requireUUID(1)
                let members = byEpoch[epochID] ?? []
                guard let rate = epoch.double(2), rate.isFinite, rate > 0 else { throw ArchiveError.invalidTranscript }
                let known = try database.rows("SELECT start_frame,end_frame FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=? AND kind='no_speech'", [.text(epochID.uuidString), .text(configurationFingerprint)]).map { try batchRange($0) }
                let previouslyFrozen = try database.rows("SELECT r.start_frame,r.end_frame FROM transcription_batch_ranges r JOIN transcription_batches b ON b.id=r.batch_id WHERE r.epoch_id=? AND b.configuration_hash=?", [.text(epochID.uuidString), .text(configurationFingerprint)]).map { try batchRange($0) }
                let noSpeech = try subtractBatchRanges(known, removing: previouslyFrozen)
                for (kind, ranges) in [("speech", try FrameRange.union(members.map(\.coreFrames))), ("no_speech", noSpeech)] {
                    for range in ranges {
                        try database.execute("INSERT INTO transcription_batch_ranges(batch_id,session_id,epoch_id,timebase,start_frame,end_frame,kind) VALUES(?,?,?,?,?,?,?)", [
                            .text(id.uuidString), .text(sessionID.uuidString), .text(epochID.uuidString), .double(rate),
                            .integer(range.start), .integer(range.end), .text(kind)
                        ])
                    }
                }
            }
            return try transcriptionBatch(id: id)
        }
    }

    public func transcriptionBatches(limit: Int = 50) throws -> [TranscriptionBatch] {
        guard (1...200).contains(limit) else { throw ArchiveError.invalidQuery }
        return try database.rows("SELECT id FROM transcription_batches ORDER BY rowid DESC LIMIT ?", [.integer(Int64(limit))])
            .map { try transcriptionBatch(id: $0.requireUUID(0)) }
    }

    public func activeTranscriptionBatches() throws -> [TranscriptionBatch] {
        try database.rows("SELECT id FROM transcription_batches WHERE state!='completed' ORDER BY rowid")
            .map { try transcriptionBatch(id: $0.requireUUID(0)) }
    }

    public func transcriptionBatch(id: UUID) throws -> TranscriptionBatch {
        guard let row = try database.rows("SELECT configuration_hash,state,end_reason,current_execution FROM transcription_batches WHERE id=?", [.text(id.uuidString)]).first else {
            throw TranscriptionBatchError.missingBatch(id)
        }
        guard let state = TranscriptionBatchState(rawValue: try row.requireString(1)) else { throw ArchiveError.database(11) }
        let reason = try batchEndReason(row.string(2))
        let execution: TranscriptionBatchExecution?
        if let value = row.string(3) {
            guard let executionID = UUID(uuidString: value),
                  let run = try database.rows("SELECT origin FROM transcription_batch_executions WHERE id=? AND batch_id=?", [.text(value), .text(id.uuidString)]).first,
                  let origin = TranscriptionBatchOrigin(rawValue: try run.requireString(0)) else { throw ArchiveError.database(11) }
            execution = TranscriptionBatchExecution(batchID: id, executionID: executionID, origin: origin)
        } else { execution = nil }
        let members = try database.rows("SELECT m.window_id,m.epoch_id,m.start_frame,m.end_frame,w.state FROM transcription_batch_windows m LEFT JOIN analysis_windows w ON w.id=m.window_id WHERE m.batch_id=? ORDER BY m.rowid", [.text(id.uuidString)])
        let ranges = try database.rows("SELECT r.session_id,r.epoch_id,r.timebase,r.start_frame,r.end_frame,r.kind,s.deleted FROM transcription_batch_ranges r JOIN sessions s ON s.id=r.session_id WHERE r.batch_id=? ORDER BY r.epoch_id,r.start_frame,r.kind", [.text(id.uuidString)])
        var coverage: [TranscriptionBatchCoverage] = []
        let grouped = try Dictionary(grouping: ranges, by: { try $0.requireUUID(1) })
        for epochID in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let parts = grouped[epochID], let first = parts.first, let rate = first.double(2) else { throw ArchiveError.database(11) }
            let frozen = try FrameRange.union(parts.map { try batchRange($0, offset: 3) })
            let raw = try parts.filter { $0.string(5) == "unprepared" }.map { try batchRange($0, offset: 3) }
            let analyzedSilence = raw.isEmpty ? [] : try database.rows("SELECT start_frame,end_frame FROM analysis_coverage WHERE epoch_id=? AND configuration_hash=? AND kind='no_speech'",
                [.text(epochID.uuidString), .text(try row.requireString(0))]).map { try batchRange($0) }
            let noSpeech = try FrameRange.union(parts.filter { $0.string(5) == "no_speech" }.map { try batchRange($0, offset: 3) }
                + CoverageRanges.intersection(raw, analyzedSilence))
            let removed = first.integer(6) == 1
            let recognized = try members.filter { $0.string(1) == epochID.uuidString && $0.string(4) == "complete" }.map { try batchRange($0, offset: 2) }
            let completed = try CoverageRanges.intersection(frozen, removed ? [] : noSpeech + recognized)
            coverage.append(TranscriptionBatchCoverage(sessionID: try first.requireUUID(0), epochID: epochID,
                timebaseHz: rate, frozen: frozen, noSpeech: noSpeech,
                completed: completed, removed: removed ? frozen : []))
        }
        return TranscriptionBatch(id: id, configurationFingerprint: try row.requireString(0), state: state,
            endReason: reason, execution: execution, windowIDs: try members.map { try $0.requireString(0) }, coverage: coverage)
    }

    public func beginTranscriptionBatch(id: UUID, executionID: UUID = UUID(), origin: TranscriptionBatchOrigin) throws -> TranscriptionBatchExecution {
        try database.transaction {
            let batch = try transcriptionBatch(id: id)
            let execution = TranscriptionBatchExecution(batchID: id, executionID: executionID, origin: origin)
            if batch.execution == execution, batch.state == .running { return execution }
            guard batch.state != .paused else { throw TranscriptionBatchError.paused }
            guard batch.state == .ready,
                  try database.rows("SELECT 1 FROM transcription_batch_executions WHERE id=?", [.text(executionID.uuidString)]).isEmpty else {
                throw TranscriptionBatchError.staleExecution
            }
            try database.execute("INSERT INTO transcription_batch_executions(id,batch_id,origin) VALUES(?,?,?)", [.text(executionID.uuidString), .text(id.uuidString), .text(origin.rawValue)])
            try database.execute("UPDATE transcription_batches SET state='running',end_reason=NULL,current_execution=? WHERE id=?", [.text(executionID.uuidString), .text(id.uuidString)])
            return execution
        }
    }

    /// The first end event wins. Replaying an old completion cannot end a newer execution.
    public func finishTranscriptionBatch(execution: TranscriptionBatchExecution, reason: TranscriptionBatchEndReason) throws -> TranscriptionBatch {
        try database.transaction {
            guard let run = try database.rows("SELECT batch_id,origin,end_reason FROM transcription_batch_executions WHERE id=?", [.text(execution.executionID.uuidString)]).first,
                  run.string(0) == execution.batchID.uuidString, run.string(1) == execution.origin.rawValue else { throw TranscriptionBatchError.staleExecution }
            if run.string(2) != nil { return try transcriptionBatch(id: execution.batchID) }
            try validateBatchExecution(execution)
            if reason == .completed {
                if let fingerprint = try database.rows("SELECT configuration_hash FROM transcription_batches WHERE id=?", [.text(execution.batchID.uuidString)]).first?.string(0) {
                    try registerOverlappingBatchWindows(batchID: execution.batchID, fingerprint: fingerprint)
                }
                let unfinished = try database.rows("SELECT 1 FROM transcription_batch_windows m JOIN sessions s ON s.id=m.session_id LEFT JOIN analysis_windows w ON w.id=m.window_id WHERE m.batch_id=? AND s.deleted=0 AND (w.id IS NULL OR w.state!='complete') LIMIT 1", [.text(execution.batchID.uuidString)])
                guard unfinished.isEmpty else { throw TranscriptionBatchError.incomplete }
                let batch = try transcriptionBatch(id: execution.batchID)
                for coverage in batch.coverage {
                    guard try CoverageRanges.subtract(coverage.frozen, coverage.completed + coverage.removed).isEmpty else {
                        throw TranscriptionBatchError.incomplete
                    }
                }
            }
            if reason == .backgroundExpired, execution.origin != .backgroundProcessing { throw ArchiveError.invalidQuery }
            try endBatchExecution(execution, reason: reason)
            return try transcriptionBatch(id: execution.batchID)
        }
    }

    public func resumeTranscriptionBatch(id: UUID) throws -> TranscriptionBatch {
        try database.transaction {
            let batch = try transcriptionBatch(id: id)
            guard batch.state != .running else { throw TranscriptionBatchError.staleExecution }
            if batch.state == .paused { try database.execute("UPDATE transcription_batches SET state='ready' WHERE id=?", [.text(id.uuidString)]) }
            return try transcriptionBatch(id: id)
        }
    }

    // Called inside Archive's startup recovery transaction, before stale window attempts are cleared.
    func recoverInterruptedBatches() throws {
        for row in try database.rows("SELECT b.id,x.id,x.origin FROM transcription_batches b JOIN transcription_batch_executions x ON x.id=b.current_execution WHERE b.state='running'") {
            guard let origin = TranscriptionBatchOrigin(rawValue: try row.requireString(2)) else { throw ArchiveError.database(11) }
            let execution = TranscriptionBatchExecution(batchID: try row.requireUUID(0), executionID: try row.requireUUID(1), origin: origin)
            try endBatchExecution(execution, reason: origin == .continuedProcessing ? .systemEndedUnknown : .interrupted)
        }
    }

    func validateBatchExecution(_ execution: TranscriptionBatchExecution, fingerprint: String? = nil) throws {
        guard let row = try database.rows("SELECT b.configuration_hash FROM transcription_batches b JOIN transcription_batch_executions x ON x.id=b.current_execution WHERE b.id=? AND b.state='running' AND b.current_execution=? AND x.origin=? AND x.end_reason IS NULL", [.text(execution.batchID.uuidString), .text(execution.executionID.uuidString), .text(execution.origin.rawValue)]).first else {
            throw TranscriptionBatchError.staleExecution
        }
        if let fingerprint, row.string(0) != fingerprint { throw TranscriptionBatchError.configurationMismatch }
    }

    func batchReserves(_ window: ArchiveAnalysisWindow, except batchID: UUID? = nil) throws -> Bool {
        let rows = try database.rows("SELECT m.batch_id FROM transcription_batch_windows m JOIN transcription_batches b ON b.id=m.batch_id WHERE m.epoch_id=? AND m.start_frame<? AND m.end_frame>? AND b.state!='completed'", [.text(window.epochID.uuidString), .integer(window.coreFrames.end), .integer(window.coreFrames.start)])
        return try rows.contains { try $0.requireUUID(0) != batchID }
            || batchReservesAnalysis(epochID: window.epochID, except: batchID)
    }

    func batchReservesSession(_ sessionID: UUID) throws -> Bool {
        try !database.rows("""
            SELECT 1 FROM transcription_batch_ranges r JOIN transcription_batches b ON b.id=r.batch_id
            WHERE r.session_id=? AND r.kind IN ('speech','unprepared') AND b.state!='completed' LIMIT 1
            """, [.text(sessionID.uuidString)]).isEmpty
    }

    private func endBatchExecution(_ execution: TranscriptionBatchExecution, reason: TranscriptionBatchEndReason) throws {
        let state: TranscriptionBatchState
        switch reason {
        case .completed: state = .completed
        case .userPaused, .systemEndedUnknown: state = .paused
        case .backgroundExpired, .interrupted: state = .ready
        }
        try database.execute("UPDATE transcription_batch_executions SET end_reason=? WHERE id=? AND end_reason IS NULL", [.text(reason.rawValue), .text(execution.executionID.uuidString)])
        try database.execute("UPDATE transcription_batches SET state=?,end_reason=?,current_execution=NULL WHERE id=?", [.text(state.rawValue), .text(reason.rawValue), .text(execution.batchID.uuidString)])
        // Invalidate writes immediately; the worker releases its own audio leases only after native returns.
        try database.execute("UPDATE analysis_windows SET state='pending',attempt_id=NULL WHERE state='running' AND id IN (SELECT window_id FROM transcription_batch_windows WHERE batch_id=?)", [.text(execution.batchID.uuidString)])
        try database.execute("UPDATE analysis_epochs SET attempt_id=NULL WHERE epoch_id IN (SELECT epoch_id FROM transcription_batch_ranges WHERE batch_id=? AND kind='unprepared')",
            [.text(execution.batchID.uuidString)])
    }
}

private func batchEndReason(_ value: String?) throws -> TranscriptionBatchEndReason? {
    guard let value else { return nil }
    guard let reason = TranscriptionBatchEndReason(rawValue: value) else { throw ArchiveError.database(11) }
    return reason
}

private func batchRange(_ row: SQLRow, offset: Int = 0) throws -> FrameRange {
    try FrameRange(start: row.requireInt(offset), count: row.requireInt(offset + 1) - row.requireInt(offset))
}

private func subtractBatchRanges(_ ranges: [FrameRange], removing removed: [FrameRange]) throws -> [FrameRange] {
    let removed = try FrameRange.union(removed)
    var result: [FrameRange] = []
    for range in try FrameRange.union(ranges) {
        var cursor = range.start
        for cut in removed where cut.end > cursor && cut.start < range.end {
            if cut.start > cursor { result.append(try FrameRange(start: cursor, count: cut.start - cursor)) }
            cursor = min(range.end, max(cursor, cut.end))
        }
        if cursor < range.end { result.append(try FrameRange(start: cursor, count: range.end - cursor)) }
    }
    return result
}
