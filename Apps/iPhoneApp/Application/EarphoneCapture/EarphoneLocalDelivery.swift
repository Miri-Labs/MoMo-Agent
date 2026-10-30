import Foundation
import MoMoArchive
import MoMoContracts
import MoMoRecording

/// Hands the phone's own earphone ledger to the archive in-process, without WatchConnectivity.
/// The ledger keeps each original until the archive's receipt is applied on both sides.
struct EarphoneLocalDelivery: Sendable {
    struct Result: Sendable {
        var chunkIDs: [UUID] = []
        var events = 0
        /// A deletion of the session still being captured waits for the runtime's stop barrier.
        var deletionAwaitingStop: UUID?
        var changed: Bool { !chunkIDs.isEmpty || events > 0 }
    }

    let store: RecordingStore
    let archive: ArchiveStore
    let deviceID: UUID
    let stagingURL: URL

    func bindReceiver() async throws {
        try await store.bindReceiver(deviceID: deviceID, libraryInstanceID: archive.libraryInstanceID)
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
    }

    func deliver(capturingSessionID: UUID?) async throws -> Result {
        var result = Result()
        try await deliverChunks(into: &result)
        try await deliverCaptureEvents(into: &result)
        result.deletionAwaitingStop = try await applyDeletions(capturingSessionID: capturingSessionID)
        _ = try await store.cleanupAcknowledgedChunks()
        return result
    }

    private func deliverChunks(into result: inout Result) async throws {
        for chunk in try await store.pendingChunks() {
            // The archive moves what it preserves; the ledger's original stays until the receipt lands.
            let staged = stagingURL.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: chunk.audioURL, to: staged)
            let item: InboxItem
            do { item = try archive.inbox.preserve(fileURL: staged, envelope: chunk.envelope) }
            catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
            let receipt: Receipt
            switch try await archive.commitReceivedChunk(item) {
            case .accepted(let issued), .duplicate(let issued), .restored(let issued): receipt = issued
            // A deleted session is cleaned by its deletion; the others leave no receipt to apply yet.
            case .deleted, .expired, .missing, .noLongerPending: continue
            }
            let applied = try await store.applyReceipt(receipt)
            try await archive.applyReceipt(applied)
            result.chunkIDs.append(receipt.chunkID)
        }
    }

    private func deliverCaptureEvents(into result: inout Result) async throws {
        while true {
            let batch = try await store.controlBatch(kind: .capture, after: 0)
            if batch.isEmpty { return }
            for entry in batch {
                switch entry.message {
                case .epochEnded(let event): try await archive.receiveEpochEnd(event)
                case .epochInterrupted(let event): try await archive.receiveEpochInterruption(event)
                case .captureMark(let mark): try await archive.receiveMark(mark)
                default: continue
                }
                try await store.markControlPreserved(entry.message, receiverDeviceID: deviceID,
                                                     libraryInstanceID: archive.libraryInstanceID)
                result.events += 1
            }
        }
    }

    private func applyDeletions(capturingSessionID: UUID?) async throws -> UUID? {
        var awaitingStop: UUID?
        for deletion in try await archive.pendingDeletions() {
            // Watch sessions are unknown to this ledger and stay with the watch transport.
            guard try await store.intent(sessionID: deletion.sessionID) != nil else { continue }
            try await store.prepareDeletion(deletion, deviceID: deviceID)
            if deletion.sessionID == capturingSessionID {
                awaitingStop = deletion.sessionID
                continue
            }
            let applied = try await store.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
            try await archive.applyDeletionAcknowledgement(applied)
        }
        return awaitingStop
    }
}
