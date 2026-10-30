import CSQLite
import Foundation
import Synchronization
import Testing
import MoMoContracts
@testable import MoMoRecording

@Suite(.serialized)
struct CaptureCapacityTests {
    @Test func admissionUsesMeasuredLedgerAndRejectsUnknownCapacity() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let budget = try await store.captureCapacityBudget()
        #expect(budget.nextAudioBytes == 960_000 * 4)
        #expect(budget.closingAndCopyBytes == budget.nextAudioBytes)
        #expect(budget.metadataBytes > 0)
        let exact = CaptureCapacityReader { _ in budget.requiredBytes }
        #expect(try await store.checkCaptureCapacity(reader: exact).availableBytes == budget.requiredBytes)
        let insufficient = CaptureCapacityReader { _ in budget.requiredBytes - 1 }
        do {
            _ = try await store.checkCaptureCapacity(reader: insufficient)
            Issue.record("Admission must reject a capacity below the complete write budget")
        } catch CaptureCapacityError.insufficient(let snapshot) {
            #expect(snapshot.stage == .starting)
            #expect(snapshot.availableBytes == snapshot.budget.requiredBytes - 1)
        }
        await #expect(throws: CaptureCapacityError.unavailable) {
            try await store.checkCaptureCapacity(reader: CaptureCapacityReader { _ in throw CocoaError(.fileReadNoPermission) })
        }
        await #expect(throws: CaptureCapacityError.unavailable) {
            try await store.checkCaptureCapacity(reader: CaptureCapacityReader { _ in -1 })
        }
        #expect(try await store.pendingChunks().isEmpty)
        #expect(try await store.latestActiveSession() == nil)
    }

    @Test func liveVolumeCapacityIsReadWithoutAllocatingDiskPressure() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let snapshot = try await store.checkCaptureCapacity()
        #expect(snapshot.availableBytes >= snapshot.budget.requiredBytes)
        #expect(snapshot.budget.requiredBytes > 0)
    }

    @Test func firstChunkRefusalCreatesNeitherAudioNorDraft() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
        pair.continuation.yield(CapturedAudioBlock(mono: Array(repeating: 0.02, count: 1_024), sampleTime: 0,
            uptime: 1, wallClock: Date(), normalizedLevel: 0.02))
        pair.continuation.finish()
        let directory = fixture.root.appendingPathComponent("encoder")
        let manifest = fixture.envelope.manifest
        do {
            _ = try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
                directory: directory, sessionID: manifest.sessionID, epochID: manifest.epochID,
                sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "capacity-tests", sourceKind: .fixture,
                store: store, capacityReader: CaptureCapacityReader { _ in 0 }, progress: { _ in })
            Issue.record("Expected capacity refusal before creating the first audio file")
        } catch CaptureCapacityError.insufficient(let snapshot) { #expect(snapshot.stage == .starting) }
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
        #expect(try await store.pendingChunks().isEmpty)
    }

    @Test func rotationRefusalPreservesTheChunkClosedInsideTheSameInputBlock() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let manifest = fixture.envelope.manifest
        try await store.saveIntent(.recording, sessionID: manifest.sessionID)
        try await store.beginEpoch(sessionID: manifest.sessionID, epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID)
        let calls = CapacityReadCount()
        // Platform fault injection only: no quota, synthetic full volume, or repeated audio file is used.
        let capacity = CaptureCapacityReader { _ in
            calls.next() == 1 ? Int64.max : 0
        }
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
        for block in 0..<3 {
            let frames = (0..<8_192).map { Float(sin(Double(block * 8_192 + $0) * 0.043)) * 0.04 }
            pair.continuation.yield(CapturedAudioBlock(mono: frames, sampleTime: Int64(block * 8_192),
                uptime: Double(block + 1), wallClock: Date(), normalizedLevel: 0.04))
        }
        pair.continuation.finish()
        let directory = fixture.root.appendingPathComponent("encoder")
        let snapshot: CaptureCapacitySnapshot
        do {
            _ = try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
                directory: directory, sessionID: manifest.sessionID, epochID: manifest.epochID,
                sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "capacity-tests", sourceKind: .fixture,
                store: store, capacityReader: capacity, targetSeconds: 1, progress: { _ in })
            Issue.record("Expected admission refusal before opening a second AAC container")
            return
        } catch CaptureCapacityError.insufficient(let value) { snapshot = value }
        #expect(snapshot.stage == .rotating && snapshot.availableBytes == 0)
        #expect(calls.value == 2)
        let chunks = try await store.pendingChunks()
        let chunk = try #require(chunks.first)
        #expect(chunks.count == 1)
        #expect(chunk.envelope.manifest.frames.count == 16_000)
        #expect(chunk.envelope.manifest.byteCount < snapshot.budget.nextAudioBytes)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)

        let event = CaptureDiagnostic(code: .lowSpace, sessionID: manifest.sessionID, epochID: manifest.epochID,
            observedFrames: 16_000, inputSampleRate: 16_000, capacity: snapshot)
        try await store.recordCapacityStop(event)
        _ = try await store.recordEpochInterruption(sessionID: manifest.sessionID, epochID: manifest.epochID,
            sourceDeviceID: manifest.sourceDeviceID, lastObservedFrame: 16_000, reason: .failed)
        #expect(try await store.cleanupAcknowledgedChunks().isEmpty)
        let reopened = try fixture.store()
        #expect(try await reopened.intent(sessionID: manifest.sessionID) == .paused)
        let persistedEvent = try #require(await reopened.captureDiagnostics().first)
        // WireJSON persists millisecond timestamps, rather than Date's submillisecond precision.
        #expect(try WireJSON.encode(persistedEvent) == WireJSON.encode(event))
        #expect(abs(persistedEvent.timestamp.timeIntervalSince(event.timestamp)) < 0.001)
        #expect(try await reopened.pendingChunks().count == 1)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        var restored = CaptureState()
        restored.restore(intent: try #require(await reopened.intent(sessionID: manifest.sessionID)))
        let automaticResume = restored.resumeAfterInterruption(systemAllows: true)
        #expect(automaticResume == nil)
        try await reopened.saveIntent(.stopped, sessionID: manifest.sessionID)
        try await reopened.recordCapacityStop(event)
        #expect(try await reopened.intent(sessionID: manifest.sessionID) == .stopped)
    }

    @Test func anAdmittedShortTailStillSealsWithoutOpeningAnotherContainer() async throws {
        guard #available(macOS 15, iOS 18, watchOS 11, *) else { return }
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let calls = CapacityReadCount()
        let reader = CaptureCapacityReader { _ in
            calls.next() == 1 ? Int64.max : 0
        }
        let pair = AsyncThrowingStream<CapturedAudioBlock, any Error>.makeStream()
        pair.continuation.yield(CapturedAudioBlock(mono: Array(repeating: 0.03, count: 8_000), sampleTime: 0,
            uptime: 1, wallClock: Date(), normalizedLevel: 0.03))
        pair.continuation.finish()
        let manifest = fixture.envelope.manifest
        let count = try await CaptureEncoder.run(input: AudioCaptureInput(sampleRate: 16_000, blocks: pair.stream),
            directory: fixture.root.appendingPathComponent("encoder"), sessionID: manifest.sessionID,
            epochID: manifest.epochID, sourceDeviceID: manifest.sourceDeviceID, sourceBuild: "capacity-tests",
            sourceKind: .fixture, store: store, capacityReader: reader, targetSeconds: 1, progress: { _ in })
        #expect(count == 8_000)
        #expect(calls.value == 1)
        #expect(try await store.pendingChunks().first?.envelope.manifest.frames.count == 8_000)
    }

    @Test func diagnosticsAreBoundedAndMigrationKeepsUnconfirmedAudio() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        // Recreate the immediately preceding schema, with its real chunk ledger and original audio intact.
        let oldDatabase = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try removeSchemaFiveTables(oldDatabase)
        try oldDatabase.execute("DROP TABLE capture_diagnostics")
        try oldDatabase.execute("PRAGMA user_version = 3")
        let migrated = try fixture.store()
        var last: CaptureDiagnostic?
        for index in 0..<(RecordingStore.diagnosticLimit + 5) {
            let event = CaptureDiagnostic(code: .inputStalled, sessionID: fixture.envelope.manifest.sessionID,
                observedFrames: Int64(index))
            try await migrated.recordDiagnostic(event)
            last = event
        }
        let reopened = try fixture.store()
        let diagnostics = try await reopened.captureDiagnostics()
        #expect(diagnostics.count == RecordingStore.diagnosticLimit)
        let latest = try #require(diagnostics.first)
        let expectedLatest = try #require(last)
        #expect(try WireJSON.encode(latest) == WireJSON.encode(expectedLatest))
        #expect(abs(latest.timestamp.timeIntervalSince(expectedLatest.timestamp)) < 0.001)
        #expect(diagnostics.last?.observedFrames == 5)
        #expect(try await reopened.pendingChunkCount() == 1)
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == chunk.envelope.manifest.audioSHA256)
        let payload = String(decoding: try WireJSON.encode(diagnostics), as: UTF8.self)
        #expect(!payload.contains(fixture.root.path) && !payload.contains("input.pcm"))
    }

    @Test func largeDatabasePageCountStaysBoundedToWorkingSetPages() throws {
        let baseline = try CaptureCapacityBudget(targetFrames: 960_000, databasePageSize: 4_096, databasePageCount: 64)
        let historical25MB = try CaptureCapacityBudget(targetFrames: 960_000, databasePageSize: 4_096, databasePageCount: 6_400)
        let historical60MB = try CaptureCapacityBudget(targetFrames: 960_000, databasePageSize: 4_096, databasePageCount: 15_360)
        #expect(historical25MB == baseline)
        #expect(historical60MB == baseline)
        #expect(historical60MB.requiredBytes < 16_000_000)
    }

    @Test func historicalLedgerPruningReclaimsConfirmedHistoryAndPreservesUnconfirmedAndRecentRows() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let sourceDeviceID = fixture.envelope.manifest.sourceDeviceID
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let now = baseTime.addingTimeInterval(20 * 86_400)
        let audioHash = try ContentHash.sha256(fileAt: fixture.source)
        let byteCount = try #require(
            (try FileManager.default.attributesOfItem(atPath: fixture.source.path)[.size] as? NSNumber)?.int64Value
        )

        func makeEnvelope(sessionID: UUID, epochID: UUID, sequence: Int64, sealedAt: Date) throws -> ManifestEnvelope {
            let manifest = try ChunkManifest(
                sessionID: sessionID,
                epochID: epochID,
                chunkID: UUID(),
                sourceDeviceID: sourceDeviceID,
                sourceBuild: "prune-tests",
                sequence: sequence,
                frames: FrameRange(start: sequence * 1_000, count: 1_000),
                timebaseHz: 16_000,
                wallClockAnchor: sealedAt,
                timezoneOffset: 0,
                codec: .pcmInt16,
                sampleRate: 16_000,
                channels: 1,
                decodedFrameCount: 1_000,
                byteCount: byteCount,
                audioSHA256: audioHash,
                sealedAt: sealedAt,
                sourceKind: .fixture
            )
            return try ManifestEnvelope(manifest: manifest)
        }

        // 1. Old confirmed session (3 chunks sealed 20 days ago, all acknowledged, cleaned, reconciled, and control-confirmed).
        let oldSession = UUID(), oldEpoch = UUID()
        try await store.saveIntent(.recording, sessionID: oldSession)
        try await store.beginEpoch(sessionID: oldSession, epochID: oldEpoch, sourceDeviceID: sourceDeviceID)
        var oldConfirmedChunkIDs: [UUID] = []
        var receiptsByChunk: [UUID: Receipt] = [:]
        for seq in 0..<3 {
            let env = try makeEnvelope(sessionID: oldSession, epochID: oldEpoch, sequence: Int64(seq), sealedAt: baseTime)
            let sealed = try await store.sealChunk(audioAt: fixture.source, envelope: env)
            let receipt = try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: sealed.envelope.manifest.chunkID,
                audioSHA256: sealed.envelope.manifest.audioSHA256,
                manifestSHA256: sealed.envelope.manifestSHA256
            )
            receiptsByChunk[receipt.chunkID] = receipt
            let applied = try await store.applyReceipt(receipt)
            try await store.markControlPreserved(.receiptApplied(applied), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
            oldConfirmedChunkIDs.append(receipt.chunkID)
        }
        let endedEvent = try CaptureEpochEnded(sessionID: oldSession, epochID: oldEpoch, sourceDeviceID: sourceDeviceID, endFrame: 3_000, reason: .stopped)
        try await store.recordEpochEnded(endedEvent)
        try await store.markControlPreserved(.epochEnded(endedEvent), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        try await store.saveIntent(.stopped, sessionID: oldSession)

        // 2. Old unconfirmed chunk (sealed 20 days ago, receipt applied & cleaned, but ReceiptApplied NOT confirmed in control_deliveries).
        let unconfirmedSession = UUID(), unconfirmedEpoch = UUID()
        try await store.saveIntent(.stopped, sessionID: unconfirmedSession)
        let unconfirmedEnv = try makeEnvelope(sessionID: unconfirmedSession, epochID: unconfirmedEpoch, sequence: 0, sealedAt: baseTime)
        let unconfirmedChunk = try await store.sealChunk(audioAt: fixture.source, envelope: unconfirmedEnv)
        let unconfirmedReceipt = try Receipt(
            receiverDeviceID: fixture.receiverID,
            libraryInstanceID: fixture.libraryID,
            chunkID: unconfirmedChunk.envelope.manifest.chunkID,
            audioSHA256: unconfirmedChunk.envelope.manifest.audioSHA256,
            manifestSHA256: unconfirmedChunk.envelope.manifestSHA256
        )
        receiptsByChunk[unconfirmedReceipt.chunkID] = unconfirmedReceipt
        _ = try await store.applyReceipt(unconfirmedReceipt)

        // 3. Old deleted session (sealed 20 days ago, deletion completed and DeleteApplied confirmed in control_deliveries).
        let deletedSession = UUID(), deletedEpoch = UUID()
        try await store.saveIntent(.recording, sessionID: deletedSession)
        let deletedEnv = try makeEnvelope(sessionID: deletedSession, epochID: deletedEpoch, sequence: 0, sealedAt: baseTime)
        let deletedChunk = try await store.sealChunk(audioAt: fixture.source, envelope: deletedEnv)
        let deletion = try DeleteSession(
            sessionID: deletedSession,
            generation: 1,
            receiverDeviceID: fixture.receiverID,
            libraryInstanceID: fixture.libraryID
        )
        try await store.prepareDeletion(deletion, deviceID: sourceDeviceID)
        let deleteApplied = try await store.completeDeletionAfterCaptureStopped(deletionID: deletion.deletionID)
        try await store.markControlPreserved(.deleteApplied(deleteApplied), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)

        // 4. Four recent confirmed chunks (sealed 1 day ago) to sit inside minimumRetainedChunks = 4.
        let recentSession = UUID(), recentEpoch = UUID()
        try await store.saveIntent(.stopped, sessionID: recentSession)
        var recentChunkIDs: [UUID] = []
        for seq in 0..<4 {
            let env = try makeEnvelope(
                sessionID: recentSession,
                epochID: recentEpoch,
                sequence: Int64(seq),
                sealedAt: now.addingTimeInterval(-86_400)
            )
            let sealed = try await store.sealChunk(audioAt: fixture.source, envelope: env)
            let receipt = try Receipt(
                receiverDeviceID: fixture.receiverID,
                libraryInstanceID: fixture.libraryID,
                chunkID: sealed.envelope.manifest.chunkID,
                audioSHA256: sealed.envelope.manifest.audioSHA256,
                manifestSHA256: sealed.envelope.manifestSHA256
            )
            receiptsByChunk[receipt.chunkID] = receipt
            let applied = try await store.applyReceipt(receipt)
            try await store.markControlPreserved(.receiptApplied(applied), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
            recentChunkIDs.append(receipt.chunkID)
        }
        let recentEnded = try CaptureEpochEnded(sessionID: recentSession, epochID: recentEpoch, sourceDeviceID: sourceDeviceID, endFrame: 4_000, reason: .stopped)
        try await store.recordEpochEnded(recentEnded)
        try await store.markControlPreserved(.epochEnded(recentEnded), receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)

        _ = try await store.cleanupAcknowledgedChunks()

        // Run multiple full reconciliation rounds to advance round.cursor and generate > 2 processed reconciliation_requests.
        for roundIndex in 0..<4 {
            let roundDate = baseTime.addingTimeInterval(Double(roundIndex + 2) * 86_400)
            while let request = try await store.nextReconciliationRequest(sourceDeviceID: sourceDeviceID, beginNewRound: true, now: roundDate) {
                let items = try request.items.map { item in
                    try ReconcileResult(chunkID: item.chunkID, state: .received(try #require(receiptsByChunk[item.chunkID])))
                }
                let reply = try ReconcileResponse(
                    requestID: request.messageID,
                    requestSHA256: request.requestSHA256,
                    sourceDeviceID: request.sourceDeviceID,
                    receiverDeviceID: fixture.receiverID,
                    libraryInstanceID: fixture.libraryID,
                    results: items
                )
                _ = try await store.applyReconciliationResponse(reply, now: roundDate)
                break
            }
        }

        let db = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        let maxRowBefore = try db.rows("SELECT COALESCE(MAX(rowid), 0) FROM chunks") { sqlite3_column_int64($0, 0) }.first ?? 0

        let pruned = try await store.pruneHistoricalLedger(
            now: now,
            retentionInterval: 14 * 86_400,
            minimumRetainedChunks: 4,
            retainedProcessedRequests: 2
        )
        #expect(pruned == 4)

        for id in oldConfirmedChunkIDs {
            #expect(try await store.chunk(id: id) == nil)
        }
        #expect(try await store.chunk(id: deletedChunk.envelope.manifest.chunkID) == nil)
        // Unconfirmed chunk must NOT be pruned even though it is >14 days old and removed from CaptureReady.
        #expect(try await store.chunk(id: unconfirmedChunk.envelope.manifest.chunkID)?.state == .removed)
        // Recent 4 chunks inside minimumRetainedChunks floor must stay intact.
        for id in recentChunkIDs {
            #expect(try await store.chunk(id: id)?.state == .removed)
        }

        let maxRowAfter = try db.rows("SELECT COALESCE(MAX(rowid), 0) FROM chunks") { sqlite3_column_int64($0, 0) }.first ?? 0
        #expect(maxRowAfter == maxRowBefore)
        let requestCount = try db.rows("SELECT COUNT(*) FROM reconciliation_requests") { sqlite3_column_int64($0, 0) }.first ?? 0
        #expect(requestCount <= 2)
        let workingOwnerCount = try db.rows("SELECT COUNT(*) FROM working_owners") { sqlite3_column_int64($0, 0) }.first ?? 0
        #expect(workingOwnerCount == 0)
        let oldEventCount = try db.rows("SELECT COUNT(*) FROM capture_events WHERE session_id=?", [.text(oldSession.uuidString)]) { sqlite3_column_int64($0, 0) }.first ?? 0
        #expect(oldEventCount == 0)
    }
}

@available(macOS 15, iOS 18, watchOS 11, *)
private final class CapacityReadCount: Sendable {
    private let count = Mutex(0)
    func next() -> Int { count.withLock { value in value += 1; return value } }
    var value: Int { count.withLock { $0 } }
}
