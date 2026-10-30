import Foundation
import MoMoContracts

/// Rebuilt once per store opening; committed chunk changes update only affected epochs.
/// This cache owns no receipts, files or deletion decisions.
final class RecordingQueueIndex {
    let sealedSessionID: UUID?
    init(sealedSessionID: UUID?) { self.sealedSessionID = sealedSessionID }
    private struct Entry {
        let sessionID: UUID
        let epochID: UUID
        let frames: FrameRange
        let timebaseHz: Double
        let bytes: Int64
        let state: RecordedChunkState
    }
    private struct Totals {
        var pendingCount = 0
        var pendingBytes: Int64 = 0
        var pendingDuration: TimeInterval = 0
        var sealed: [UUID: TimeInterval] = [:]
    }
    private var entries: [Int64: Entry] = [:]
    private var epochs: [UUID: [Int64: Entry]] = [:]
    private var totals: [UUID: Totals] = [:]
    private var sealed: [UUID: TimeInterval] = [:]
    private(set) var pendingCount = 0
    private(set) var pendingBytes: Int64 = 0
    private(set) var pendingDuration: TimeInterval = 0

    func sealedDuration(sessionID: UUID) -> TimeInterval { max(0, sealed[sessionID] ?? 0) }

    func apply(_ rows: [(Int64, ManifestEnvelope, String)], changedRows: Set<Int64>) throws {
        var changedEpochs = Set<UUID>()
        for rowID in changedRows {
            if let old = entries.removeValue(forKey: rowID) {
                epochs[old.epochID]?.removeValue(forKey: rowID)
                changedEpochs.insert(old.epochID)
            }
        }
        for (rowID, envelope, stateName) in rows {
            let manifest = envelope.manifest
            guard let state = RecordedChunkState(rawValue: stateName) else {
                throw RecordingError.contentConflict(manifest.chunkID)
            }
            guard state == .ready || manifest.sessionID == sealedSessionID else { continue }
            let entry = Entry(sessionID: manifest.sessionID, epochID: manifest.epochID, frames: manifest.frames,
                timebaseHz: manifest.timebaseHz, bytes: manifest.byteCount, state: state)
            entries[rowID] = entry
            epochs[entry.epochID, default: [:]][rowID] = entry
            changedEpochs.insert(entry.epochID)
        }
        // Remove all old contributions before adding new ones, avoiding transient byte overflow on moves.
        for epochID in changedEpochs {
            if let old = totals.removeValue(forKey: epochID) {
                pendingCount -= old.pendingCount
                pendingBytes -= old.pendingBytes
                pendingDuration -= old.pendingDuration
                for (session, duration) in old.sealed { sealed[session, default: 0] -= duration }
            }
        }
        for epochID in changedEpochs {
            guard let epoch = epochs[epochID], !epoch.isEmpty else { epochs.removeValue(forKey: epochID); continue }
            let pending = epoch.values.filter { $0.state == .ready }
            var total = Totals()
            total.pendingCount = pending.count
            for entry in pending {
                let sum = total.pendingBytes.addingReportingOverflow(entry.bytes)
                guard !sum.overflow else { throw RecordingReconciliationError.responseMismatch }
                total.pendingBytes = sum.partialValue
            }
            total.pendingDuration = try duration(pending)
            for (sessionID, chunks) in Dictionary(grouping: epoch.values.filter { $0.state != .deleted && $0.sessionID == sealedSessionID }, by: \.sessionID) {
                total.sealed[sessionID] = try duration(chunks)
            }
            let sum = pendingBytes.addingReportingOverflow(total.pendingBytes)
            guard !sum.overflow else { throw RecordingReconciliationError.responseMismatch }
            pendingBytes = sum.partialValue
            pendingCount += total.pendingCount
            pendingDuration += total.pendingDuration
            for (session, duration) in total.sealed { sealed[session, default: 0] += duration }
            totals[epochID] = total
        }
        pendingDuration = pendingCount == 0 ? 0 : max(0, pendingDuration)
    }

    private func duration(_ entries: [Entry]) throws -> TimeInterval {
        guard let first = entries.first else { return 0 }
        guard entries.allSatisfy({ $0.timebaseHz == first.timebaseHz }) else {
            throw RecordingReconciliationError.responseMismatch
        }
        return try FrameRange.union(entries.map(\.frames)).reduce(0) { $0 + Double($1.count) / first.timebaseHz }
    }
}
