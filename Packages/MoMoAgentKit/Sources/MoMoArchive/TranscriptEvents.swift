import Foundation
import MoMoContracts

public struct TranscriptEvent: Sendable {
    public let source: SourceReference
    public let frames: FrameRange
    public let start: Date
    public let end: Date
    public let text: String
    public let observedAt: Date
    public var id: String { "recording:\(source.sessionID):\(source.spanID)" }
}

extension ArchiveStore {
    /// Uses sample clocks, not session starts; all rows are materialized in this actor turn.
    public func transcriptEvents(from: Date, before: Date, limit: Int,
                                 after: Date? = nil, afterID: String = "", descending: Bool = false) throws -> [TranscriptEvent] {
        guard from.timeIntervalSince1970.isFinite, before.timeIntervalSince1970.isFinite,
              from < before, (1...51).contains(limit), after?.timeIntervalSince1970.isFinite != false,
              afterID.utf8.count <= 200 else { throw ArchiveError.invalidQuery }
        let comparison = descending ? "<" : ">", order = descending ? "DESC" : "ASC"
        let rows = try database.rows("""
            WITH epoch_bounds AS (
              SELECT epoch_id,MIN(rowid) AS sample,MAX(json_extract(CAST(manifest AS TEXT),'$.frames.start')
                +json_extract(CAST(manifest AS TEXT),'$.frames.count')) AS end_frame FROM chunks GROUP BY epoch_id
            ), eligible_sessions AS (
              SELECT DISTINCT c.session_id FROM epoch_bounds b JOIN chunks c ON c.rowid=b.sample
              WHERE (julianday(json_extract(CAST(c.manifest AS TEXT),'$.wallClockAnchor'))-2440587.5)*86400 < ? + 0.001
                AND (julianday(json_extract(CAST(c.manifest AS TEXT),'$.wallClockAnchor'))-2440587.5)*86400
                  +b.end_frame/CAST(json_extract(CAST(c.manifest AS TEXT),'$.timebaseHz') AS REAL) > ? - 0.001
            ), timed AS (
              SELECT s.id AS session_id,s.generation,s.transcript_version,v.document,p.value AS span,
                'recording:'||s.id||':'||json_extract(p.value,'$.id') AS event_id,
                ROUND((julianday(json_extract(CAST(a.manifest AS TEXT),'$.wallClockAnchor'))-2440587.5)*86400
                  +json_extract(p.value,'$.frames.start')/CAST(json_extract(CAST(a.manifest AS TEXT),'$.timebaseHz') AS REAL),3) AS start_at,
                ROUND((julianday(json_extract(CAST(a.manifest AS TEXT),'$.wallClockAnchor'))-2440587.5)*86400
                  +(json_extract(p.value,'$.frames.start')+json_extract(p.value,'$.frames.count'))
                    /CAST(json_extract(CAST(a.manifest AS TEXT),'$.timebaseHz') AS REAL),3) AS end_at
              FROM eligible_sessions e JOIN sessions s ON s.id=e.session_id JOIN transcript_versions v ON v.session_id=s.id AND v.version=s.transcript_version
              JOIN json_each(CAST(v.document AS TEXT),'$.spans') p
              JOIN chunks a ON a.id=json_extract(p.value,'$.chunkID')
              WHERE s.deleted=0 AND s.projection_blocked=0
            ) SELECT session_id,generation,transcript_version,span,start_at,end_at,
                json_extract(CAST(document AS TEXT),'$.updatedAt') FROM timed
              WHERE start_at<? AND end_at>? AND (? IS NULL OR start_at \(comparison) ? OR (start_at=? AND event_id \(comparison) ?))
              ORDER BY start_at \(order),event_id \(order) LIMIT ?
            """, [.double(before.timeIntervalSince1970), .double(from.timeIntervalSince1970),
                  .double(before.timeIntervalSince1970), .double(from.timeIntervalSince1970),
                  after.map { .double($0.timeIntervalSince1970) } ?? .null,
                  after.map { .double($0.timeIntervalSince1970) } ?? .null,
                  after.map { .double($0.timeIntervalSince1970) } ?? .null,
                  .text(afterID), .integer(Int64(limit))])
        return try rows.map { row in
            let span = try WireJSON.decode(TranscriptSpan.self, from: Data(row.requireString(3).utf8))
            guard let start = row.double(4), let end = row.double(5) else { throw ArchiveError.database(11) }
            let updated = try WireJSON.decode(Date.self, from: JSONEncoder().encode(row.requireString(6)))
            return TranscriptEvent(source: SourceReference(sessionID: try row.requireUUID(0), spanID: span.id,
                transcriptVersion: try row.requireInt(2), generation: try row.requireInt(1)), frames: span.frames,
                start: Date(timeIntervalSince1970: start),
                end: Date(timeIntervalSince1970: end), text: span.text, observedAt: updated)
        }
    }
}
