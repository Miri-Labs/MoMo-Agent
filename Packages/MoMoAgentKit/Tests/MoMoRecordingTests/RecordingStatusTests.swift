import Foundation
import Testing
import MoMoContracts
@testable import MoMoRecording

@Suite struct RecordingStatusTests {
    @Test func coldStatusUsesLedgerIdentityAndQueueWithoutOpeningAudioOrClaimingCapture() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        try await store.saveIntent(.recording, sessionID: fixture.envelope.manifest.sessionID)
        try FileManager.default.removeItem(at: chunk.audioURL)
        let status = try await store.coldStatus(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID, sourceBuild: "tests")
        guard case .watch(let payload) = status.payload else { Issue.record("Expected watch status"); return }
        #expect(payload.receiverLibraryInstanceID == fixture.libraryID)
        #expect(payload.pendingChunkCount == 1 && payload.pendingBytes == fixture.envelope.manifest.byteCount)
        #expect(payload.activity == .idle && payload.sessionID == nil && payload.epochID == nil)
        #expect(payload.lastSampleFrame == nil && payload.capturedDuration == 0)
        #expect(try await store.intent(sessionID: fixture.envelope.manifest.sessionID) == .recording)
        let reopened = try fixture.store()
        let next = try await reopened.coldStatus(sourceDeviceID: status.sourceDeviceID, sourceBuild: "tests")
        #expect(next.sourceStoreInstanceID == status.sourceStoreInstanceID && next.revision == status.revision + 1)
    }

    @Test func freshForegroundObservationRenewsUnchangedStatusWithoutBindingAReceiver() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let payload = try WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: nil, epochID: nil,
            activity: .idle, capturedDuration: 0, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0)
        let first = try await store.saveStatus(sourceDeviceID: fixture.envelope.manifest.sourceDeviceID,
            sourceBuild: "tests", payload: payload, sampledAt: Date(timeIntervalSince1970: 100))
        let fresh = try await store.saveStatus(sourceDeviceID: first.sourceDeviceID, sourceBuild: "tests",
            payload: payload, sampledAt: Date(timeIntervalSince1970: 200), refreshObservation: true)
        #expect(fresh.payload == first.payload && fresh.sourceStoreInstanceID == first.sourceStoreInstanceID)
        #expect(fresh.revision == first.revision + 1 && fresh.sampledAt == Date(timeIntervalSince1970: 200))
        #expect(try await store.boundReceiver() == nil)
        #expect(try await store.pendingReceiptApplications().isEmpty)
        let replay = try await store.saveStatus(sourceDeviceID: first.sourceDeviceID, sourceBuild: "tests", payload: payload)
        #expect(replay == fresh)
    }

    @Test func storeIdentityAndRevisionSurviveRestartAndUnchangedObservations() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let m = fixture.envelope.manifest
        let idle = try WatchCaptureStatus(receiverLibraryInstanceID: nil, sessionID: nil, epochID: nil,
            activity: .idle, capturedDuration: 0, sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0)
        let first = try await store.saveStatus(sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", payload: idle,
            sampledAt: Date(timeIntervalSince1970: 100.125))
        #expect(first.revision == 1)
        let reopened = try fixture.store()
        let unchanged = try await reopened.saveStatus(sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", payload: idle,
            sampledAt: Date(timeIntervalSince1970: 500))
        #expect(unchanged == first)

        _ = try await reopened.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        let summary = try await reopened.queueSummary(sessionID: m.sessionID)
        let active = try WatchCaptureStatus(receiverLibraryInstanceID: fixture.libraryID, sessionID: m.sessionID, epochID: m.epochID,
            activity: .recording, capturedDuration: 0.02, sealedDuration: summary.sealedDuration,
            pendingChunkCount: summary.pendingChunkCount, pendingBytes: summary.pendingBytes,
            lastSampleFrame: 320, timebaseHz: 16_000, lastSampleAge: 0.1)
        let changed = try await reopened.saveStatus(sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", payload: active)
        #expect(changed.revision == first.revision + 1 && changed.sourceStoreInstanceID == first.sourceStoreInstanceID)
        let upgraded = try await reopened.saveStatus(sourceDeviceID: m.sourceDeviceID, sourceBuild: "next-build", payload: active)
        #expect(upgraded.revision == changed.revision + 1 && upgraded.sourceStoreInstanceID == first.sourceStoreInstanceID)
        #expect(try await reopened.pendingChunks().count == 1)
        #expect(try await reopened.boundReceiver() == nil) // Publishing observation never binds a library.
    }

    @Test func queueDurationUnionsFramesAndKeepsEpochsSeparate() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let m = fixture.envelope.manifest
        let otherEpoch = UUID()
        var envelopes: [ManifestEnvelope] = []
        for (sequence, pair) in [(m.epochID, Int64(0)), (m.epochID, 80), (otherEpoch, 0)].enumerated() {
            let envelope = try ManifestEnvelope(manifest: ChunkManifest(sessionID: m.sessionID, epochID: pair.0,
                sourceDeviceID: m.sourceDeviceID, sourceBuild: "status-tests", sequence: Int64(sequence),
                frames: FrameRange(start: pair.1, count: 160), timebaseHz: 16_000,
                wallClockAnchor: m.wallClockAnchor, timezoneOffset: 0, codec: .pcmInt16,
                sampleRate: 16_000, channels: 1, decodedFrameCount: 160, byteCount: m.byteCount,
                audioSHA256: m.audioSHA256, sourceKind: .fixture))
            _ = try await store.sealChunk(audioAt: fixture.source, envelope: envelope)
            envelopes.append(envelope)
        }
        _ = try await store.sealChunk(audioAt: fixture.source, envelope: envelopes[0])
        let summary = try await store.queueSummary(sessionID: m.sessionID)
        #expect(summary.pendingChunkCount == 3 && summary.pendingBytes == m.byteCount * 3)
        #expect(abs(summary.pendingDuration - 0.025) < 0.000_001)
        #expect(summary.sealedDuration == summary.pendingDuration)
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        _ = try await store.applyReceipt(Receipt(receiverDeviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID,
            chunkID: envelopes[0].manifest.chunkID, audioSHA256: m.audioSHA256, manifestSHA256: envelopes[0].manifestSHA256))
        _ = try await store.cleanupAcknowledgedChunks()
        let after = try await store.queueSummary(sessionID: m.sessionID)
        #expect(after.pendingChunkCount == 2 && after.pendingBytes == m.byteCount * 2)
        #expect(abs(after.pendingDuration - 0.02) < 0.000_001 && after.sealedDuration == summary.sealedDuration)
    }

    @Test func schemaFourMigrationPreservesAudioIntentAndStableReceiptApplication() async throws {
        let fixture = try RecordingFixture()
        defer { fixture.clean() }
        let store = try fixture.store()
        let m = fixture.envelope.manifest
        let chunk = try await store.sealChunk(audioAt: fixture.source, envelope: fixture.envelope)
        try await store.saveIntent(.paused, sessionID: m.sessionID)
        try await store.bindReceiver(deviceID: fixture.receiverID, libraryInstanceID: fixture.libraryID)
        let application = try await store.applyReceipt(fixture.receipt())
        let database = try RecordingDatabase(url: fixture.root.appendingPathComponent("watch/recording.sqlite"))
        try removeSchemaFiveTables(database)
        try database.execute("PRAGMA user_version=4")

        let migrated = try fixture.store()
        #expect(try await migrated.intent(sessionID: m.sessionID) == .paused)
        #expect(try await migrated.pendingReceiptApplications() == [application])
        #expect(try ContentHash.sha256(fileAt: chunk.audioURL) == m.audioSHA256)
        let request = try #require(await migrated.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID))
        #expect(request.items == [try ReconcileChunkIdentity(envelope: fixture.envelope)])
        let payload = try WatchCaptureStatus(receiverLibraryInstanceID: fixture.libraryID, sessionID: m.sessionID,
            epochID: nil, activity: .paused, capturedDuration: 0.01, sealedDuration: 0.01, pendingChunkCount: 0, pendingBytes: 0)
        let status = try await migrated.saveStatus(sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", payload: payload)
        let reopened = try fixture.store()
        #expect(try await reopened.saveStatus(sourceDeviceID: m.sourceDeviceID, sourceBuild: "tests", payload: payload) == status)
        #expect(try await reopened.nextReconciliationRequest(sourceDeviceID: m.sourceDeviceID) == request)
    }

    @Test func earlyPhoneStatusWaitsForIdentityWithoutReplacingItsSourceTime() throws {
        var cache = ReceiverStatusCache()
        let device = UUID(), library = UUID()
        let snapshot = try phoneStatus(device: device, library: library, revision: 1)
        try cache.receive(snapshot)
        #expect(cache.boundStatus == nil)
        cache.bind(deviceID: device, libraryInstanceID: library)
        #expect(cache.boundStatus == snapshot)
        try cache.receive(snapshot)
        #expect(cache.count == 1 && cache.boundStatus?.sampledAt == snapshot.sampledAt)
    }

    @Test func lateOldLibraryStatusCannotEvictThePendingReceiverSnapshot() throws {
        var cache = ReceiverStatusCache()
        let device = UUID(), oldLibrary = UUID(), newLibrary = UUID()
        cache.bind(deviceID: device, libraryInstanceID: oldLibrary)
        let original = try phoneStatus(device: device, library: oldLibrary, revision: 1)
        try cache.receive(original)
        let candidate = try phoneStatus(device: device, library: newLibrary, revision: 1)
        try cache.receive(candidate)
        cache.expectReceiver(deviceID: device, libraryInstanceID: newLibrary)
        try cache.receive(phoneStatus(device: device, library: oldLibrary, revision: 2))
        for _ in 0..<10 { try cache.receive(phoneStatus(device: device, library: UUID(), revision: 1)) }
        #expect(cache.count == ReceiverStatusCache.maximumSnapshots)
        #expect(cache.boundStatus?.sourceStoreInstanceID == oldLibrary)
        cache.bind(deviceID: device, libraryInstanceID: newLibrary)
        #expect(cache.boundStatus == candidate)
        try cache.receive(original)
        #expect(cache.boundStatus == candidate)
    }

    private func phoneStatus(device: UUID, library: UUID, revision: Int64) throws -> StatusSnapshot {
        try StatusSnapshot(sourceDeviceID: device, sourceBuild: "tests", sourceStoreInstanceID: library,
            revision: revision, sampledAt: Date(timeIntervalSince1970: Double(revision)),
            payload: .phone(PhoneArchiveStatus(libraryInstanceID: library, recordingCount: Int(revision), pendingAnalysisCount: 0, pendingReceiptCount: 0)))
    }
}
