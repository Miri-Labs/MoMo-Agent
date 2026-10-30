import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct AudioStoragePolicyTests {
    @Test func permanentAndStorageLimitPersistWithoutOverwritingExistingDays() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        #expect(try await store.audioRetentionPolicy() == .days(7))
        #expect(try await store.storageLimitBytes() == 20_000_000_000)
        try await store.setAudioRetentionPolicy(.days(19))
        #expect(try await fixture.store().audioRetentionPolicy() == .days(19))
        try await store.setAudioRetentionPolicy(.forever)
        try await store.setStorageLimitBytes(10_000_000_000)
        let reopened = try fixture.store()
        #expect(try await reopened.audioRetentionPolicy() == .forever)
        #expect(try await reopened.storageLimitBytes() == 10_000_000_000)
        await #expect(throws: ArchiveError.invalidQuery) { try await store.setAudioRetentionPolicy(.days(0)) }
        await #expect(throws: ArchiveError.invalidQuery) { try await store.setAudioRetentionPolicy(.days(366)) }
        await #expect(throws: ArchiveError.invalidQuery) { try await store.setStorageLimitBytes(0) }
        await #expect(throws: ArchiveError.invalidQuery) { try await store.setStorageLimitBytes(-1) }
        #expect(try await store.audioRetentionPolicy() == .forever)
        #expect(try await store.storageLimitBytes() == 10_000_000_000)
    }

    @Test func permanentKeepsOldAudioButQuotaRemovesOldestInBoundedPassesAndKeepsText() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let now = Date()
        let chunks = try [2, 0, 1].map { index in
            try fixture.envelope(startFrame: Int64(index * 1600), sequence: Int64(index),
                                 sealedAt: now.addingTimeInterval(Double(index - 1000) * 86_400))
        }
        try await populate(fixture, store: store, chunks: chunks)
        let document = try await store.readTranscript(sessionID: fixture.sessionID)
        let floors = [fixture.epochID: Int64(4800)]
        try await store.setAudioRetentionPolicy(.forever)
        #expect(try await store.applyRetention(now: .distantFuture, replayFloors: floors).isEmpty)
        try await store.setStorageLimitBytes(Int64(fixture.audio.count))
        #expect(try await store.applyRetention(now: now, replayFloors: floors, limit: 1) == [chunks[1].manifest.chunkID])
        #expect(try await store.applyRetention(now: now, replayFloors: floors, limit: 1) == [chunks[2].manifest.chunkID])
        #expect(try await store.applyRetention(now: now, replayFloors: floors).isEmpty)
        let usage = try await store.storageUsage(modelDirectory: nil)
        #expect(usage.audioBytes == Int64(fixture.audio.count))
        let retained = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(retained.version == document.version && retained.spans == document.spans)
        let lease = try await store.acquireAudioLease(chunkID: chunks[0].manifest.chunkID)
        #expect(try Data(contentsOf: lease.audioURL) == fixture.audio)
        await store.releaseAudioLease(id: lease.id)
        let reopened = try fixture.store()
        #expect(try await reopened.recordingSummary(sessionID: fixture.sessionID).audioState == .partiallyExpired)
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans == document.spans)
    }

    enum Protection: CaseIterable { case kept, leasedRecording, noReceipt, pendingAnalysis, noReplayFloor, insufficientReplayFloor }

    @Test(arguments: Protection.allCases)
    func quotaSkipsProtectedAudioAndNeverBlocksNewReceipts(protection: Protection) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let chunks = try [fixture.envelope(), fixture.envelope(startFrame: 1600, sequence: 1)]
        try await populate(fixture, store: store, chunks: chunks,
                           confirm: protection != .noReceipt, analyze: protection != .pendingAnalysis)
        try await store.setAudioRetentionPolicy(.forever)
        try await store.setStorageLimitBytes(1)
        if protection == .kept { try await store.setKeepAudio(sessionID: fixture.sessionID, keep: true) }
        let lease = protection == .leasedRecording ? try await store.acquireAudioLease(chunkID: chunks[0].manifest.chunkID) : nil
        let floors: [UUID: Int64] = protection == .noReplayFloor ? [:] : [fixture.epochID: protection == .insufficientReplayFloor ? 0 : 3200]
        #expect(try await store.applyRetention(now: .distantFuture, replayFloors: floors).isEmpty)
        #expect(try await store.storageUsage(modelDirectory: nil).audioBytes == Int64(fixture.audio.count * 2))
        let incoming = try fixture.envelope(startFrame: 3200, sequence: 2)
        guard case .accepted = try await store.commitReceivedChunk(fixture.deliver(incoming, to: store)) else {
            Issue.record("Storage policy must not reject incoming audio"); return
        }
        if let lease {
            await store.releaseAudioLease(id: lease.id)
            #expect(try await store.applyRetention(now: .distantFuture, replayFloors: floors).count == 2)
        }
    }

    private func populate(_ fixture: Fixture, store: ArchiveStore, chunks: [ManifestEnvelope],
                          confirm: Bool = true, analyze: Bool = true) async throws {
        for chunk in chunks {
            guard case .accepted(let receipt) = try await store.commitReceivedChunk(fixture.deliver(chunk, to: store)) else {
                Issue.record("Expected accepted fixture"); return
            }
            if confirm { try await store.applyReceipt(ReceiptApplied(receipt: receipt)) }
        }
        if analyze {
            for _ in chunks {
                let ticket = try #require(await store.claimAnalysisJob(configurationHash: "model-v1"))
                _ = try await store.commitTranscript(ticket: ticket, spans: fixture.spans(ticket))
            }
        }
    }
}
