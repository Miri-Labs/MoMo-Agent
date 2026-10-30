import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveStatusTests {
    @Test func acceptedObservationKeepsCachedFreshnessAndDeletedSessionBarrier() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        _ = try await fixture.deliver(to: archive)
        let cached = try fixture.snapshot(library: archive.libraryInstanceID, revision: 2)
        let first = try await archive.receiveWatchStatusReport(cached, restored: true)
        #expect(first.changed && first.observation?.restored == true)
        let duplicate = try await archive.receiveWatchStatusReport(cached, restored: false)
        #expect(!duplicate.changed && duplicate.observation?.observedAt == nil)
        #expect(duplicate.observation?.restored == true)
        let old = try fixture.snapshot(library: archive.libraryInstanceID, revision: 1)
        let outdated = try await archive.receiveWatchStatusReport(old, restored: false)
        #expect(!outdated.changed && outdated.observation?.snapshot == cached)
        let live = try fixture.snapshot(library: archive.libraryInstanceID, revision: 3)
        let newer = try await archive.receiveWatchStatusReport(live, restored: false,
            observedAt: Date(timeIntervalSince1970: 20))
        #expect(newer.changed && newer.observation?.observedAt == Date(timeIntervalSince1970: 20))
        _ = try await archive.deleteSession(id: fixture.session)
        let deleted = try await archive.receiveWatchStatusReport(live, restored: false)
        #expect(!deleted.changed && deleted.observation == nil)
    }

    @Test func idleObservationBindsNoRecordingAndCannotAcknowledgeAudio() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        let snapshot = try StatusSnapshot(sourceDeviceID: fixture.source, sourceBuild: "test",
            sourceStoreInstanceID: fixture.storeID, revision: 1,
            payload: .watch(WatchCaptureStatus(receiverLibraryInstanceID: archive.libraryInstanceID,
                sessionID: nil, epochID: nil, activity: .idle, capturedDuration: 0, sealedDuration: 0,
                pendingChunkCount: 0, pendingBytes: 0)))
        let report = try await archive.receiveWatchStatusReport(snapshot, restored: false)
        #expect(!report.changed && report.observation?.snapshot == snapshot)
        #expect(try await archive.recordings().isEmpty)
        #expect(try await archive.pendingReceipts().isEmpty)
        #expect(try await archive.latestWatchStatus() == nil)
    }

    @Test func captureEventsBindStatusSourceBeforeTheFirstAudioFile() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        try await archive.receiveMark(CaptureMark(sessionID: fixture.session, epochID: fixture.epoch,
            sourceDeviceID: fixture.source, sourceFrame: 0))
        let wrong = try fixture.snapshot(library: archive.libraryInstanceID, revision: 1, sourceID: UUID())
        await #expect(throws: ArchiveStatusError.sourceMismatch) { try await archive.receiveWatchStatus(wrong, restored: true) }
        let correct = try fixture.snapshot(library: archive.libraryInstanceID, revision: 1)
        #expect(try await archive.receiveWatchStatus(correct, restored: true))
        _ = try await fixture.deliver(to: archive)
        #expect(try await archive.watchStatus(sessionID: fixture.session)?.snapshot == correct)
    }

    @Test func cachedStatusSurvivesRestartWithoutBecomingFreshOrAcknowledgingAudio() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        let snapshot = try fixture.snapshot(library: archive.libraryInstanceID, revision: 4)
        #expect(try await archive.receiveWatchStatus(snapshot, restored: true))
        let latest = try #require(await archive.latestWatchStatus())
        #expect(latest.snapshot == snapshot)
        #expect(latest.restored)
        #expect(latest.observedAt == nil)
        // A context can precede its audio, but cannot manufacture a recording or receipt.
        #expect(try await archive.recordings().isEmpty)
        #expect(try await archive.pendingReceipts().isEmpty)
        let receipt = try await fixture.deliver(to: archive)
        let reopened = try fixture.archive()
        let observation = try #require(await reopened.watchStatus(sessionID: fixture.session))
        #expect(observation.restored)
        #expect(observation.observedAt == nil)
        #expect(try await !reopened.receiveWatchStatus(snapshot, restored: false, observedAt: Date(timeIntervalSince1970: 500)))
        let again = try #require(await reopened.watchStatus(sessionID: fixture.session))
        #expect(again.observedAt == nil)
        let coverage = try await reopened.recordingCoverage(sessionID: fixture.session, configurationFingerprint: nil)
        #expect(coverage.watchCapturedDuration == 30)
        #expect(coverage.watchStatusUpdatedAt == snapshot.sampledAt)
        #expect(coverage.receivedDuration == 0.1)
        #expect(try await reopened.pendingReceipts() == [receipt])
    }

    @Test func statusRejectsStaleConflictingCrossLibraryAndCrossStoreReports() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        _ = try await fixture.deliver(to: archive)
        let current = try fixture.snapshot(library: archive.libraryInstanceID, revision: 8)
        #expect(try await archive.receiveWatchStatus(current, restored: false, observedAt: Date(timeIntervalSince1970: 50)))
        let older = try fixture.snapshot(library: archive.libraryInstanceID, revision: 7)
        #expect(try await !archive.receiveWatchStatus(older, restored: false))
        let conflict = try fixture.snapshot(library: archive.libraryInstanceID, revision: 8, duration: 31)
        await #expect(throws: ArchiveStatusError.conflictingRevision) { try await archive.receiveWatchStatus(conflict, restored: false) }
        let wrongLibrary = try fixture.snapshot(library: UUID(), revision: 9)
        await #expect(throws: ArchiveStatusError.receiverMismatch) { try await archive.receiveWatchStatus(wrongLibrary, restored: false) }
        let wrongStore = try fixture.snapshot(library: archive.libraryInstanceID, revision: 9, storeID: UUID())
        await #expect(throws: ArchiveStatusError.sourceMismatch) { try await archive.receiveWatchStatus(wrongStore, restored: false) }
        let observation = try #require(await archive.watchStatus(sessionID: fixture.session))
        #expect(observation.snapshot == current)
        #expect(observation.observedAt == Date(timeIntervalSince1970: 50))
        let newer = try fixture.snapshot(library: archive.libraryInstanceID, revision: 9, duration: 32)
        #expect(try await archive.receiveWatchStatus(newer, restored: false, observedAt: Date(timeIntervalSince1970: 60)))
        _ = try await archive.deleteSession(id: fixture.session)
        #expect(try await !archive.receiveWatchStatus(newer, restored: false))
        #expect(try await archive.watchStatus(sessionID: fixture.session) == nil)
        #expect(try await archive.latestWatchStatus() == nil)
    }

    @Test func latestStatusUsesSampleTimeRatherThanDeliveryOrder() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        let current = try fixture.snapshot(library: archive.libraryInstanceID, revision: 1)
        try await archive.receiveWatchStatus(current, restored: false)
        let delayedPayload = try WatchCaptureStatus(receiverLibraryInstanceID: archive.libraryInstanceID,
            sessionID: UUID(), epochID: nil, activity: .stopped, capturedDuration: 0,
            sealedDuration: 0, pendingChunkCount: 0, pendingBytes: 0)
        let delayed = try StatusSnapshot(sourceDeviceID: fixture.source, sourceBuild: "test",
            sourceStoreInstanceID: fixture.storeID, revision: 100, sampledAt: Date(timeIntervalSince1970: 9.999),
            payload: .watch(delayedPayload))
        try await archive.receiveWatchStatus(delayed, restored: false)
        #expect(try await archive.latestWatchStatus()?.snapshot == current)
        #expect(try await archive.recordings().isEmpty)
    }

    @Test func phoneSummaryRevisionIsDurableAndOnlyChangesWithSourceState() async throws {
        let fixture = try StatusFixture()
        defer { fixture.remove() }
        let archive = try fixture.archive()
        let first = try await archive.phoneStatus(sourceBuild: "test", sampledAt: Date(timeIntervalSince1970: 1))
        #expect(first.revision == 1)
        _ = try await fixture.deliver(to: archive)
        let second = try await archive.phoneStatus(sourceBuild: "test", sampledAt: Date(timeIntervalSince1970: 2))
        #expect(second.revision == 2)
        guard case .phone(let phone) = second.payload else { Issue.record("Expected a phone summary"); return }
        #expect(phone.recordingCount == 1)
        #expect(phone.pendingAnalysisCount == 1)
        #expect(phone.pendingReceiptCount == 1)
        let reopened = try fixture.archive()
        #expect(try await reopened.phoneStatus(sourceBuild: "test", sampledAt: Date(timeIntervalSince1970: 100)) == second)
        let buildChanged = try await reopened.phoneStatus(sourceBuild: "next-build", sampledAt: Date(timeIntervalSince1970: 101))
        #expect(buildChanged.revision == 3)
        #expect(buildChanged.sourceStoreInstanceID == archive.libraryInstanceID)
        _ = try await reopened.deleteSession(id: fixture.session)
        let deleted = try await reopened.phoneStatus(sourceBuild: "next-build")
        guard case .phone(let afterDeletion) = deleted.payload else { Issue.record("Expected a phone summary"); return }
        #expect(afterDeletion.recordingCount == 0)
        #expect(afterDeletion.pendingReceiptCount == 0)
    }
}

private struct StatusFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("momo-status-\(UUID())")
    let session = UUID(), epoch = UUID(), source = UUID(), receiver = UUID(), storeID = UUID()
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func archive() throws -> ArchiveStore { try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: receiver) }
    func snapshot(library: UUID, revision: Int64, duration: Double = 30, storeID: UUID? = nil, sourceID: UUID? = nil) throws -> StatusSnapshot {
        let watch = try WatchCaptureStatus(receiverLibraryInstanceID: library, sessionID: session, epochID: epoch,
            activity: .recording, capturedDuration: duration, sealedDuration: 0.1, pendingChunkCount: 1, pendingBytes: 3200,
            lastSampleFrame: Int64(duration * 16_000), timebaseHz: 16_000, lastSampleAge: 0.01)
        return try StatusSnapshot(sourceDeviceID: sourceID ?? source, sourceBuild: "test", sourceStoreInstanceID: storeID ?? self.storeID,
            revision: revision, sampledAt: Date(timeIntervalSince1970: 10), payload: .watch(watch))
    }
    func deliver(to archive: ArchiveStore) async throws -> Receipt {
        let audio = Fixture.audioData()
        let path = root.appendingPathComponent("delivery-\(UUID()).wav")
        try audio.write(to: path)
        let manifest = try ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: source, sourceBuild: "test",
            sequence: 0, frames: FrameRange(start: 0, count: 1600), timebaseHz: 16_000,
            wallClockAnchor: Date(timeIntervalSince1970: 1), timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000,
            channels: 1, decodedFrameCount: 1600, byteCount: Int64(audio.count), audioSHA256: ContentHash.sha256(audio), sourceKind: .watch)
        let item = try archive.inbox.preserve(fileURL: path, envelope: ManifestEnvelope(manifest: manifest))
        guard case .accepted(let receipt) = try await archive.commitReceivedChunk(item) else { throw ArchiveError.invalidInbox }
        return receipt
    }
}
