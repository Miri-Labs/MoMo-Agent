import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct IncomingAudioRepairTests {
    @Test(arguments: [0, 1, 2])
    func missingComponentsReconcileAndRepairWithTheOriginalReceipt(component: Int) async throws {
        let f = try RepairFixture()
        defer { f.fixture.remove() }
        let (store, receipt, audio) = try await f.receive()
        if component != 1 { try FileManager.default.removeItem(at: audio) }
        if component != 0 { try FileManager.default.removeItem(at: audio.appendingPathExtension("manifest.json")) }
        let request = try f.request(store)
        #expect(try await store.receiveReconcileRequest(request).results.map(\.state) == [.missing])
        let incoming = try f.fixture.deliver(f.envelope, to: store)
        guard case .restored(let repaired) = try await store.commitReceivedChunk(incoming) else { Issue.record("Expected repaired receipt"); return }
        #expect(repaired == receipt)
        #expect(try ContentHash.sha256(fileAt: audio) == f.envelope.manifest.audioSHA256)
        #expect(try ContentHash.sha256(fileAt: audio.appendingPathExtension("manifest.json")) == f.envelope.manifestSHA256)
        #expect(!FileManager.default.fileExists(atPath: incoming.directoryURL.path))
        let reopened = try f.fixture.store()
        #expect(try await reopened.pendingReceipts() == [receipt])
        #expect(try await reopened.receiveReconcileRequest(request).results.map(\.state) == [.received(receipt)])
        #expect(try await reopened.recordings().count == 1)
        #expect(try await reopened.claimAnalysisJob(configurationHash: "repair-test") != nil)
        #expect(try await reopened.claimAnalysisJob(configurationHash: "repair-test") == nil)
    }

    @Test func corruptIncomingIsRetainedWithoutRestoringOrAcknowledging() async throws {
        let f = try RepairFixture()
        defer { f.fixture.remove() }
        let (store, receipt, audio) = try await f.receive()
        try FileManager.default.removeItem(at: audio)
        let incoming = try f.fixture.deliver(f.envelope, to: store, audio: Data(repeating: 1, count: f.fixture.audio.count))
        await #expect(throws: ArchiveError.checksumMismatch) { try await store.commitReceivedChunk(incoming) }
        #expect(FileManager.default.fileExists(atPath: incoming.directoryURL.appendingPathComponent("audio").path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(try await store.pendingReceipts().isEmpty)
        let valid = try f.fixture.deliver(f.envelope, to: store)
        guard case .restored(let repaired) = try await store.repairMissingChunk(valid) else { Issue.record("Expected repaired retry"); return }
        #expect(repaired == receipt)
    }

    @Test(arguments: [false, true])
    func differentExistingBytesAreNeverOverwritten(conflictingManifest: Bool) async throws {
        let f = try RepairFixture()
        defer { f.fixture.remove() }
        let (store, _, audio) = try await f.receive()
        let manifest = audio.appendingPathExtension("manifest.json")
        let conflicted = conflictingManifest ? manifest : audio
        let missing = conflictingManifest ? audio : manifest
        let damaged = Data("preserve these different bytes".utf8)
        try damaged.write(to: conflicted)
        try FileManager.default.removeItem(at: missing)
        let incoming = try f.fixture.deliver(f.envelope, to: store)
        await #expect(throws: ArchiveError.conflictingChunk(f.envelope.manifest.chunkID)) { try await store.commitReceivedChunk(incoming) }
        #expect(try Data(contentsOf: conflicted) == damaged)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(try Data(contentsOf: incoming.directoryURL.appendingPathComponent("audio")) == f.fixture.audio)
        #expect(try await store.pendingReceipts().isEmpty)
    }

    @Test(arguments: [false, true])
    func removedDirectoriesRequireFilesConfirmationBeforeRepair(removeWholeRecording: Bool) async throws {
        let f = try RepairFixture()
        defer { f.fixture.remove() }
        let (store, receipt, audio) = try await f.receive()
        try await store.projectPendingDocuments()
        let audioDirectory = audio.deletingLastPathComponent()
        let removed = removeWholeRecording ? audioDirectory.deletingLastPathComponent() : audioDirectory
        try FileManager.default.removeItem(at: removed)
        let incoming = try f.fixture.deliver(f.envelope, to: store)
        guard case .missing = try await store.commitReceivedChunk(incoming) else { Issue.record("Directory deletion requires confirmation"); return }
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(FileManager.default.fileExists(atPath: incoming.directoryURL.path))
        #expect(try await store.pendingReceipts().isEmpty)
        let issues = try await store.recordingFileIssues()
        let issue = try #require(issues.first)
        #expect(issue.kind == (removeWholeRecording ? .missingDirectory : .missingFiles))
        _ = try await store.resolveRecordingFiles(issue, choosing: .restoreDatabase)
        guard case .restored(let repaired) = try await store.commitReceivedChunk(incoming) else { Issue.record("Confirmed directory can receive matching original audio"); return }
        #expect(repaired == receipt)
    }

    @Test(arguments: [false, true])
    func symlinkSourceAndDestinationCannotRepair(linkSource: Bool) async throws {
        let f = try RepairFixture()
        defer { f.fixture.remove() }
        let (store, _, audio) = try await f.receive()
        try FileManager.default.removeItem(at: audio)
        let outside = f.fixture.root.appendingPathComponent("outside.wav")
        try f.fixture.audio.write(to: outside)
        let incoming = try f.fixture.deliver(f.envelope, to: store)
        let linked = linkSource ? incoming.directoryURL.appendingPathComponent("audio") : audio
        if linkSource { try FileManager.default.removeItem(at: linked) }
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        await #expect(throws: linkSource ? ArchiveError.invalidInbox : ArchiveError.invalidQuery) { try await store.commitReceivedChunk(incoming) }
        #expect(try Data(contentsOf: outside) == f.fixture.audio)
        #expect(FileManager.default.fileExists(atPath: incoming.directoryURL.path))
        if linkSource { #expect(!FileManager.default.fileExists(atPath: audio.path)) }
    }

    @Test func repairWaitsForReaderAndRestartsAfterOnlyAudioWasPublished() async throws {
        let f = try RepairFixture()
        defer { f.fixture.remove() }
        let (store, receipt, audio) = try await f.receive()
        let lease = try await store.acquireAudioLease(chunkID: f.envelope.manifest.chunkID)
        try FileManager.default.removeItem(at: audio)
        try FileManager.default.removeItem(at: audio.appendingPathExtension("manifest.json"))
        let incoming = try f.fixture.deliver(f.envelope, to: store)
        guard case .missing = try await store.commitReceivedChunk(incoming) else { Issue.record("Repair must preserve the active reader's lease"); return }
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        await store.releaseAudioLease(id: lease.id)
        // Simulate termination after the atomic audio publication but before the manifest publication and DB commit.
        try FileManager.default.copyItem(at: incoming.directoryURL.appendingPathComponent("audio"), to: audio)
        let reopened = try f.fixture.store()
        let results = try await reopened.processInbox()
        let result = try #require(results.first)
        guard case .restored(let repaired) = try result.result.get() else { Issue.record("Expected resumed partial repair"); return }
        #expect(repaired == receipt)
        #expect(try await reopened.pendingReceipts() == [receipt])
        #expect(try ContentHash.sha256(fileAt: audio.appendingPathExtension("manifest.json")) == f.envelope.manifestSHA256)
    }
}

private struct RepairFixture {
    let fixture: Fixture
    let envelope: ManifestEnvelope
    init() throws {
        fixture = try Fixture()
        envelope = try fixture.envelope()
    }
    func receive() async throws -> (ArchiveStore, Receipt, URL) {
        let store = try fixture.store()
        let result = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        guard case .accepted(let receipt) = result else { throw ArchiveError.invalidInbox }
        let lease = try await store.acquireAudioLease(chunkID: envelope.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        return (store, receipt, lease.audioURL)
    }
    func request(_ store: ArchiveStore) throws -> ReconcileRequest {
        try ReconcileRequest(sourceDeviceID: fixture.deviceID, receiverDeviceID: fixture.deviceID,
            libraryInstanceID: store.libraryInstanceID, items: [ReconcileChunkIdentity(envelope: envelope)])
    }
}
