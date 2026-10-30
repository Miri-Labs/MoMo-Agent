import Foundation
import MoMoContracts

private struct StoredTranscriptHistory: Codable {
    let header: TranscriptDocument
    let blocks: [Int64]
}

extension ArchiveStore {
    private static let historyPrefix = Data("MoMoH1\n".utf8)

    /// Current versions stay JSON for timeline SQL. Historical versions share immutable blocks.
    func decodeStoredTranscript(_ data: Data) throws -> TranscriptDocument {
        guard data.starts(with: Self.historyPrefix) else {
            return try WireJSON.decode(TranscriptDocument.self, from: data)
        }
        let stored = try WireJSON.decode(StoredTranscriptHistory.self, from: Data(data.dropFirst(Self.historyPrefix.count)))
        guard stored.header.spans.isEmpty else { throw ArchiveError.invalidTranscript }
        var spans: [TranscriptSpan] = []
        for id in stored.blocks {
            guard let row = try database.rows("SELECT document FROM transcript_blocks WHERE id=? AND session_id=?",
                [.integer(id), .text(stored.header.sessionID.uuidString)]).first else { throw ArchiveError.invalidTranscript }
            let bytes = try (row.requireData(0) as NSData).decompressed(using: .lzfse) as Data
            spans += try WireJSON.decode([TranscriptSpan].self, from: bytes)
        }
        let header = stored.header
        return TranscriptDocument(sessionID: header.sessionID, version: header.version, generation: header.generation,
                                  spans: spans, updatedAt: header.updatedAt)
    }

    func compactTranscriptVersion(_ document: TranscriptDocument) throws {
        var ids: [Int64] = []
        for start in stride(from: 0, to: document.spans.count, by: 16) {
            let bytes = try WireJSON.encode(Array(document.spans[start..<min(start + 16, document.spans.count)]))
            let hash = ContentHash.sha256(bytes)
            let key: [SQLValue] = [.text(document.sessionID.uuidString), .text(hash)]
            if let row = try database.rows("SELECT id FROM transcript_blocks WHERE session_id=? AND hash=?", key).first {
                ids.append(try row.requireInt(0))
            } else {
                let compressed = try (bytes as NSData).compressed(using: .lzfse) as Data
                try database.execute("INSERT INTO transcript_blocks(session_id,hash,document) VALUES(?,?,?)", key + [.blob(compressed)])
                ids.append(try database.rows("SELECT last_insert_rowid()")[0].requireInt(0))
            }
        }
        let header = TranscriptDocument(sessionID: document.sessionID, version: document.version,
                                        generation: document.generation, spans: [], updatedAt: document.updatedAt)
        let data = Self.historyPrefix + (try WireJSON.encode(StoredTranscriptHistory(header: header, blocks: ids)))
        // Verify the reconstruction before replacing the only complete historical snapshot.
        guard try WireJSON.encode(decodeStoredTranscript(data)) == WireJSON.encode(document) else {
            throw ArchiveError.invalidTranscript
        }
        database.compactingTranscriptHistory = true
        defer { database.compactingTranscriptHistory = false }
        try database.execute("UPDATE transcript_versions SET document=?,storage_format=1 WHERE session_id=? AND version=?",
            [.blob(data), .text(document.sessionID.uuidString), .integer(document.version)])
        try database.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES('transcript_history_reclaim','1')")
        compactedBytesPendingVacuum = max(compactedBytesPendingVacuum, 1)
    }

    /// One small transaction per version permits cancellation and restart without losing references.
    public func compactTranscriptHistoryBatch(limit: Int = 2) throws -> Int {
        let keys = try database.rows("""
            SELECT v.session_id,v.version FROM transcript_versions v JOIN sessions s ON s.id=v.session_id
            WHERE v.storage_format=0 AND v.version!=s.transcript_version ORDER BY v.session_id,v.version LIMIT ?
            """, [.integer(Int64(max(1, min(limit, 16))))])
        for key in keys {
            try Task.checkCancellation()
            try database.transaction {
                guard let row = try database.rows("SELECT document FROM transcript_versions WHERE session_id=? AND version=? AND storage_format=0",
                    [.text(try key.requireString(0)), .integer(try key.requireInt(1))]).first else { return }
                try compactTranscriptVersion(decodeStoredTranscript(row.requireData(0)))
            }
        }
        return keys.count
    }

    /// Reclaim database pages once the legacy pass is complete, with room for SQLite's temporary copy.
    public func reclaimCompactedTranscriptStorage(fullVacuum: Bool = false) throws {
        if !fullVacuum {
            guard compactedBytesPendingVacuum > 0 else { return }
            try Task.checkCancellation()
            let autoVacuum = try database.rows("PRAGMA auto_vacuum").first?.integer(0) ?? 0
            let free = try database.rows("PRAGMA freelist_count").first?.integer(0) ?? 0
            if autoVacuum == 2, free > 0 {
                try database.execute("PRAGMA incremental_vacuum")
            }
            try database.execute("PRAGMA wal_checkpoint(PASSIVE)")
            let remainingUncompacted = try !database.rows("""
                SELECT 1 FROM transcript_versions v JOIN sessions s ON s.id=v.session_id
                WHERE v.storage_format=0 AND v.version!=s.transcript_version LIMIT 1
                """).isEmpty
            let remainingFree = try database.rows("PRAGMA freelist_count").first?.integer(0) ?? 0
            if (autoVacuum == 2 || remainingFree == 0) && !remainingUncompacted {
                try database.execute("DELETE FROM metadata WHERE key='transcript_history_reclaim'")
            }
            compactedBytesPendingVacuum = 0
            return
        }
        guard try !database.rows("SELECT 1 FROM metadata WHERE key='transcript_history_reclaim'").isEmpty else {
            compactedBytesPendingVacuum = 0
            return
        }
        try Task.checkCancellation()
        let free = try database.rows("PRAGMA freelist_count")[0].requireInt(0)
        let pages = try database.rows("PRAGMA page_count")[0].requireInt(0)
        let pageSize = try database.rows("PRAGMA page_size")[0].requireInt(0)
        guard free * pageSize >= 32 * 1024 * 1024, free > pages / 5 else { return }
        let capacity = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(capacity) > pages * pageSize * 2 + 64 * 1024 * 1024 else { return }
        try Task.checkCancellation()
        try database.execute("VACUUM")
        database.invalidateRowLocationsAfterVacuum()
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try database.execute("DELETE FROM metadata WHERE key='transcript_history_reclaim'")
        compactedBytesPendingVacuum = 0
    }
}
