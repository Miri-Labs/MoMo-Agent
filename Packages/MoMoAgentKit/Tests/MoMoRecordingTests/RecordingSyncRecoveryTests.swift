import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

struct RecordingSyncRecoveryTests {
    @Test func stalledCopyValidationRespectsTheGrantBudgetAndNeverConfirmsOrDeletesAudio() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), envelope = fixture.envelope
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: envelope)
        #expect(try await !store.originalAvailableForTransferRetry(envelope, maximumValidationBytes: envelope.manifest.byteCount - 1))
        #expect(try await store.chunk(id: envelope.manifest.chunkID)?.state == .ready)
        #expect(try await store.originalAvailableForTransferRetry(envelope, maximumValidationBytes: envelope.manifest.byteCount))
        #expect(try await store.confirmedReceipt(chunkID: envelope.manifest.chunkID) == nil)
        #expect(try await store.pendingChunkCount() == 1)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == envelope.manifest.audioSHA256)
        // The same size with different bytes cannot authorize cancellation of the only healthy SDK copy.
        try Data(repeating: 0, count: Int(envelope.manifest.byteCount)).write(to: chunk.audioURL)
        #expect(try await !store.originalAvailableForTransferRetry(envelope, maximumValidationBytes: envelope.manifest.byteCount))
        #expect(try await store.chunk(id: envelope.manifest.chunkID)?.state == .damaged)
        #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
    }

    @Test func fileScanPositionSurvivesColdRestartWithoutAcknowledgingTheOriginal() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        try await store.saveFileTransferPosition(4)
        let reopened = try fixture.store()
        #expect(try await reopened.fileTransferPosition() == 4)
        #expect(try await reopened.pendingChunkCount() == 1)
        #expect(try await reopened.confirmedReceipt(chunkID: chunk.envelope.manifest.chunkID) == nil)
        #expect(FileManager.default.fileExists(atPath: chunk.audioURL.path))
        try await reopened.saveFileTransferPosition(0)
        #expect(try await store.fileTransferPosition() == 0)
        await #expect(throws: RecordingReconciliationError.invalidCursor) { try await reopened.saveFileTransferPosition(-1) }
    }

    @Test func schemaFiveMigrationPreservesIntentOriginalAndStableReceiptBeforeCleanup() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), manifest = fixture.envelope.manifest
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        try await store.saveIntent(.recording, sessionID: manifest.sessionID)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let receipt = try fixture.receipt(), applied = try await store.applyReceipt(receipt)
        let database = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try database.execute("DROP TABLE control_deliveries")
        try database.execute("DROP TABLE control_positions")
        try database.execute("ALTER TABLE reconciliation_round DROP COLUMN full_history")
        try database.execute("ALTER TABLE reconciliation_round DROP COLUMN history_audited_at")
        try database.execute("PRAGMA user_version=5")
        let reopened = try fixture.store()
        #expect(try await reopened.intent(sessionID: manifest.sessionID) == .recording)
        #expect(try await reopened.pendingReceiptApplications() == [applied])
        #expect(try await reopened.confirmedReceipt(chunkID: manifest.chunkID) == receipt)
        #expect(try await reopened.controlPosition(kind: .receipt) == 0)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == manifest.audioSHA256)
    }

    @Test func persistedInboxProofStopsHistoricalReplayButDuplicateReceiptRequeuesItsApplication() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), manifest = fixture.envelope.manifest
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let event = try CaptureMark(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: manifest.sourceDeviceID, sourceFrame: 1)
        try await store.recordMark(event)
        _ = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let applied = try await store.applyReceipt(fixture.receipt())
        try await store.markControlPreserved(.captureMark(event), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        try await store.markControlPreserved(.receiptApplied(applied), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let reopened = try fixture.store()
        #expect(try await reopened.controlBatch(kind: .capture, after: 0).isEmpty)
        #expect(try await reopened.controlBatch(kind: .receipt, after: 0).isEmpty)
        #expect(try await reopened.pendingCaptureEvents() == [.captureMark(event)])
        let audit = try #require(await reopened.nextReconciliationRequest(sourceDeviceID: manifest.sourceDeviceID, beginNewRound: true))
        let auditResponse = try ReconcileResponse(requestID: audit.messageID, requestSHA256: audit.requestSHA256,
            sourceDeviceID: audit.sourceDeviceID, receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
            results: audit.items.map { try ReconcileResult(chunkID: $0.chunkID, state: .received(applied.receipt)) })
        let auditOutcome = try await reopened.applyReconciliationResponse(auditResponse)
        #expect(auditOutcome.receiptApplications == [applied])
        #expect(auditOutcome.unconfirmedReceiptApplications.isEmpty)
        #expect(try await reopened.controlBatch(kind: .receipt, after: 0).isEmpty)
        try await reopened.saveControlPosition(5, kind: .receipt)
        _ = try await reopened.applyReceipt(applied.receipt)
        #expect(try await reopened.controlPosition(kind: .receipt) == 0)
        #expect(try await reopened.controlBatch(kind: .receipt, after: 0).map(\.message) == [.receiptApplied(applied)])
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("watch/CaptureReady/\(manifest.chunkID.uuidString)/audio").path))
    }

    @Test func controlScanPositionSurvivesColdGrantsWithoutAcknowledgingSkippedEvents() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), m = fixture.envelope.manifest
        for frame in 0..<40 {
            try await store.recordMark(CaptureMark(sessionID: m.sessionID, epochID: m.epochID,
                sourceDeviceID: m.sourceDeviceID, sourceFrame: Int64(frame)))
        }
        var seen: Set<UUID> = []
        for _ in 0..<8 {
            let reopened = try fixture.store()
            let position = try await reopened.controlPosition(kind: .capture)
            let page = try await reopened.controlBatch(kind: .capture, after: position, limit: 1)
            let entry = try #require(page.first)
            #expect(seen.insert(entry.message.messageID).inserted)
            try await reopened.saveControlPosition(entry.sequence, kind: .capture)
        }
        #expect(try await store.pendingCaptureEvents().count == 40)
        #expect(try await store.hasPendingControlMessages())
    }

    @Test func receiverChangeInvalidatesDeliveryProofAndOldDeletionAuthority() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), m = fixture.envelope.manifest
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let mark = try CaptureMark(sessionID: m.sessionID, epochID: m.epochID, sourceDeviceID: m.sourceDeviceID, sourceFrame: 0)
        try await store.recordMark(mark)
        try await store.markControlPreserved(.captureMark(mark), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let legacy = try DeleteSession(sessionID: m.sessionID, generation: 1)
        await #expect(throws: RecordingError.receiverMismatch) { try await store.validateDeletionReceiver(legacy) }
        let old = try legacy.scoped(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        try await store.validateDeletionReceiver(old)
        let nextLibrary = UUID()
        try await store.replaceReceiverAfterUserConfirmation(deviceID: fixture.receiverID, libraryInstanceID: nextLibrary)
        await #expect(throws: RecordingError.receiverMismatch) {
            try await store.markControlPreserved(.captureMark(mark), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        }
        await #expect(throws: RecordingError.receiverMismatch) { try await store.prepareDeletion(old, deviceID: m.sourceDeviceID) }
        #expect(try await store.controlBatch(kind: .capture, after: 0).map(\.message) == [.captureMark(mark)])
        #expect(try await store.chunk(id: m.chunkID)?.state == .ready)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == m.audioSHA256)
    }

    @Test func upgradingAnExistingLegacyDeletionKeepsItsStableApplicationAndRequiresCurrentBinding() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store(), m = fixture.envelope.manifest
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let legacy = try DeleteSession(sessionID: m.sessionID, generation: 1)
        try await store.prepareDeletion(legacy, deviceID: m.sourceDeviceID)
        let scoped = try legacy.scoped(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        #expect(try legacy.scoped(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID) == scoped)
        try await store.prepareDeletion(scoped, deviceID: m.sourceDeviceID)
        #expect(try await store.pendingDeletions() == [scoped])
        let applied = try await store.completeDeletionAfterCaptureStopped(deletionID: legacy.deletionID)
        #expect(applied.deletionID == legacy.deletionID)
        try await store.markControlPreserved(.deleteApplied(applied), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        #expect(try await store.controlBatch(kind: .deletion, after: 0).isEmpty)
    }
}
