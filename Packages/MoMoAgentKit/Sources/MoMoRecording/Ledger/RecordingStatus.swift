import CSQLite
import Foundation
import MoMoContracts

public struct RecordingQueueSummary: Sendable {
    public let sealedDuration: TimeInterval
    public let pendingDuration: TimeInterval
    public let pendingChunkCount: Int
    public let pendingBytes: Int64
}

extension RecordingStore {
    /// Cold launches have no live sampler. Read queue metadata without opening historical audio.
    public func coldStatus(sourceDeviceID: UUID, sourceBuild: String) throws -> StatusSnapshot {
        let queue = try queueSummary(sessionID: nil)
        let payload = try WatchCaptureStatus(receiverLibraryInstanceID: boundReceiver()?.libraryInstanceID,
            sessionID: nil, epochID: nil, activity: .idle, capturedDuration: 0, sealedDuration: 0,
            pendingChunkCount: queue.pendingChunkCount, pendingBytes: queue.pendingBytes, audioBatchVersion: 1)
        return try saveStatus(sourceDeviceID: sourceDeviceID, sourceBuild: sourceBuild, payload: payload,
            refreshObservation: true)
    }

    public func queueSummary(sessionID: UUID?) throws -> RecordingQueueSummary {
        do {
            return try database.transaction {
                let version = try database.rows("PRAGMA data_version") { sqlite3_column_int64($0, 0) }.first
                // Another connection may write during tests or recovery. Rebuild from its committed state.
                if queueDataVersion != version || queueIndex?.sealedSessionID != sessionID { queueIndex = nil }
                let index = queueIndex ?? RecordingQueueIndex(sealedSessionID: sessionID)
                let changes = database.changedChunkRows
                let rows: [(Int64, ManifestEnvelope, String)]
                if queueIndex == nil {
                    if let sessionID {
                        rows = try database.rows("SELECT rowid,envelope,state FROM chunks WHERE state='ready' OR session_id=?",
                            [.text(sessionID.uuidString)], read: Self.queueRow)
                    } else {
                        rows = try database.rows("SELECT rowid,envelope,state FROM chunks WHERE state='ready'", read: Self.queueRow)
                    }
                } else if changes.isEmpty {
                    rows = []
                } else {
                    // SQLite rowids originate from its update hook, not external input.
                    let ids = changes.map(String.init).joined(separator: ",")
                    rows = try database.rows("SELECT rowid,envelope,state FROM chunks WHERE rowid IN (\(ids))", read: Self.queueRow)
                }
                noteQueueDecodedRows(rows.count)
                try index.apply(rows, changedRows: changes)
                let sealed = try sessionID.map { try isDeleted($0) ? 0 : index.sealedDuration(sessionID: $0) } ?? 0
                queueIndex = index
                queueDataVersion = version
                database.acknowledgeChunkChanges()
                return RecordingQueueSummary(sealedDuration: sealed, pendingDuration: index.pendingDuration,
                    pendingChunkCount: index.pendingCount, pendingBytes: index.pendingBytes)
            }
        } catch {
            // Failed validation/COMMIT cannot leave a partially updated derived cache in use.
            queueIndex = nil
            throw error
        }
    }

    private static func queueRow(_ row: OpaquePointer) throws -> (Int64, ManifestEnvelope, String) {
        (sqlite3_column_int64(row, 0), try WireJSON.decode(ManifestEnvelope.self, from: RecordingDatabase.data(row, 1)),
         RecordingDatabase.text(row, 2))
    }

    /// Replays reuse the last snapshot; an explicit fresh observation advances its source timestamp and revision.
    public func saveStatus(sourceDeviceID: UUID, sourceBuild: String, payload: WatchCaptureStatus,
                           sampledAt: Date = Date(), refreshObservation: Bool = false) throws -> StatusSnapshot {
        try payload.validate()
        return try database.transaction {
            guard let record = try database.rows("SELECT store_id,revision,payload FROM recording_status WHERE id=1", read: { row in
                (RecordingDatabase.text(row, 0), sqlite3_column_int64(row, 1), RecordingDatabase.data(row, 2))
            }).first, let storeID = UUID(uuidString: record.0) else { throw RecordingReconciliationError.responseMismatch }
            if !record.2.isEmpty {
                let previous = try WireJSON.decode(StatusSnapshot.self, from: record.2)
                if !refreshObservation, previous.sourceDeviceID == sourceDeviceID, previous.sourceBuild == sourceBuild, previous.payload == .watch(payload) {
                    return previous
                }
            }
            guard record.1 < Int64.max else { throw RecordingReconciliationError.invalidCursor }
            let snapshot = try StatusSnapshot(sourceDeviceID: sourceDeviceID, sourceBuild: sourceBuild,
                sourceStoreInstanceID: storeID, revision: record.1 + 1, sampledAt: sampledAt, payload: .watch(payload))
            let encoded = try WireJSON.encode(snapshot)
            try database.execute("UPDATE recording_status SET revision=?,payload=? WHERE id=1", [.integer(snapshot.revision), .blob(encoded)])
            return try WireJSON.decode(StatusSnapshot.self, from: encoded)
        }
    }
}
