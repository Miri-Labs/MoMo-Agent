import Foundation
import MoMoContracts

public struct ArchiveSyncDiagnostic: Codable, Sendable {
    public struct Day: Codable, Sendable {
        public let sourceDeviceID: String
        public let localDay: String
        public let chunkIDs: [String]
        public let retentionCounts: [String: Int]
        public let receivedBytes: Int64
    }
    public struct Commit: Codable, Sendable {
        public let chunkID: UUID
        public let committedAt: Date
    }
    public let observedAt: Date
    public let libraryInstanceID: UUID
    public let pendingReceiptCount: Int
    public let pendingReceiptCountsBySource: [String: Int]?
    public let pendingReconcileResponseCountsBySource: [String: Int]?
    public let latestCommit: Commit?
    public let days: [Day]
}

extension ArchiveStore {
    /// One actor-owned snapshot, unlike copying SQLite and its changing WAL separately.
    public func writeSyncDiagnostic(now: Date = Date(), minimumInterval: TimeInterval = 30) throws {
        guard lastSyncDiagnosticAt.map({ now.timeIntervalSince($0) >= minimumInterval }) ?? true else { return }
        lastSyncDiagnosticAt = now
        let startedMs = APIPerformanceMonitor.uptimeMilliseconds()
        let rows = try database.rows("""
            SELECT s.source_device,
              c.timebase_hz,
              c.wall_clock_anchor,
              c.timezone_offset,
              c.start_frame,
              c.id,
              c.retention,
              c.byte_count,
              CASE WHEN c.timebase_hz <= 0 OR c.wall_clock_anchor = 0 OR c.byte_count <= 0 THEN c.manifest ELSE NULL END
            FROM sessions s JOIN chunks c ON c.session_id=s.id
            WHERE s.deleted=0
            ORDER BY c.rowid
            """)
        struct DayAccumulator {
            var chunkIDs: [String] = []
            var retentionCounts: [String: Int] = [:]
            var receivedBytes: Int64 = 0
        }
        struct DayKey: Hashable {
            let sourceDeviceID: String
            let localDay: String
        }
        var dayStringsByEpochDay: [Int: String] = [:]
        func formatEpochDay(_ epochDay: Int) -> String {
            if let cached = dayStringsByEpochDay[epochDay] { return cached }
            // Civil-from-days algorithm (Howard Hinnant), matching SQLite's proleptic Gregorian date(..., 'unixepoch').
            let z = epochDay + 719_468
            let era = (z >= 0 ? z : z - 146_096) / 146_097
            let doe = z - era * 146_097
            let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
            var y = yoe + era * 400
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let d = doy - (153 * mp + 2) / 5 + 1
            let m = mp + (mp < 10 ? 3 : -9)
            if m <= 2 { y += 1 }
            let formatted = String(format: "%04d-%02d-%02d", y, m, d)
            dayStringsByEpochDay[epochDay] = formatted
            return formatted
        }
        var buckets: [DayKey: DayAccumulator] = [:]
        for row in rows {
            let sourceDevice = try row.requireString(0)
            var rate = row.double(1) ?? 0
            var anchor = row.double(2) ?? 0
            var tzOffset = row.integer(3) ?? 0
            var startFrame = row.integer(4) ?? 0
            let chunkID = try row.requireString(5)
            let retention = try row.requireString(6)
            var byteCount = row.integer(7) ?? 0
            if (rate <= 0 || anchor == 0 || byteCount <= 0),
               let manifestBlob = row.data(8),
               let manifest = try? WireJSON.decode(ChunkManifest.self, from: manifestBlob) {
                rate = manifest.timebaseHz
                anchor = manifest.wallClockAnchor.timeIntervalSince1970
                tzOffset = Int64(manifest.timezoneOffset)
                startFrame = manifest.frames.start
                byteCount = manifest.byteCount
            }
            let localSeconds = anchor + Double(tzOffset) + (rate > 0 ? Double(startFrame) / rate : 0)
            let localDay = formatEpochDay(Int(floor(localSeconds / 86_400.0)))
            let key = DayKey(sourceDeviceID: sourceDevice, localDay: localDay)
            var acc = buckets[key, default: DayAccumulator()]
            acc.chunkIDs.append(chunkID)
            acc.retentionCounts[retention, default: 0] += 1
            acc.receivedBytes += byteCount
            buckets[key] = acc
        }
        let days = buckets.keys.sorted {
            $0.sourceDeviceID == $1.sourceDeviceID ? $0.localDay < $1.localDay : $0.sourceDeviceID < $1.sourceDeviceID
        }.compactMap { key -> ArchiveSyncDiagnostic.Day? in
            guard let acc = buckets[key] else { return nil }
            return .init(sourceDeviceID: key.sourceDeviceID, localDay: key.localDay,
                         chunkIDs: acc.chunkIDs, retentionCounts: acc.retentionCounts, receivedBytes: acc.receivedBytes)
        }
        let latest = try database.rows("SELECT value FROM metadata WHERE key='latest_receive_commit'").first
            .map { try WireJSON.decode(ArchiveSyncDiagnostic.Commit.self, from: Data($0.requireString(0).utf8)) }
        let receiptCounts = try database.rows("""
            SELECT s.source_device,COUNT(*) FROM receipt_outbox r
            JOIN chunks c ON c.id=r.chunk_id JOIN sessions s ON s.id=c.session_id
            WHERE r.sent=0 AND s.deleted=0 AND c.retention='present' GROUP BY s.source_device
            """)
        let responseCounts = try database.rows("SELECT source_device,COUNT(*) FROM reconcile_requests WHERE pending=1 GROUP BY source_device")
        let snapshot = ArchiveSyncDiagnostic(observedAt: now, libraryInstanceID: libraryInstanceID,
            pendingReceiptCount: try pendingReceiptCount(),
            pendingReceiptCountsBySource: try Dictionary(uniqueKeysWithValues: receiptCounts.map { (try $0.requireString(0), Int(try $0.requireInt(1))) }),
            pendingReconcileResponseCountsBySource: try Dictionary(uniqueKeysWithValues: responseCounts.map { (try $0.requireString(0), Int(try $0.requireInt(1))) }),
            latestCommit: latest, days: days)
        try ArchiveFilePolicy.write(WireJSON.encode(snapshot), to: rootURL.appendingPathComponent("Library/Application Support/MoMoAgent/sync-receive-diagnostic.json"))
        performanceMonitor.record(.writeSyncDiagnostic, durationMs: APIPerformanceMonitor.uptimeMilliseconds() - startedMs, itemCount: rows.count)
    }

    func recordReceiveCommit(chunkID: UUID) throws {
        let value = ArchiveSyncDiagnostic.Commit(chunkID: chunkID, committedAt: Date())
        try database.execute("INSERT INTO metadata(key,value) VALUES('latest_receive_commit',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [.text(String(decoding: try WireJSON.encode(value), as: UTF8.self))])
    }
}
