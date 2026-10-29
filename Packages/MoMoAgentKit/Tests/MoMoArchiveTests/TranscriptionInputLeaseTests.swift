import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TranscriptionInputLeaseTests {
    @Test func companionsStayInEpochAndEachResultCommitsIndependently() async throws {
        let fixture = try Fixture(), other = try Fixture()
        defer { fixture.remove(); other.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("companion-windows".utf8))
        try await prepare(fixture, store: store, fingerprint: fingerprint)
        try await prepare(other, store: store, fingerprint: fingerprint)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let lease = try await store.acquireTranscriptionInputLease(ticket: first)
        let companions = try await store.claimCompanionWindows(after: first, inputLease: lease, maximumCount: 4)
        #expect(companions.count == 1)
        let second = try #require(companions.first)
        #expect(second.window.epochID == first.window.epochID)
        #expect(second.window.modelCoreFrames.start >= first.window.modelCoreFrames.end)
        #expect(second.leaseIDs.isEmpty && second.attemptID != first.attemptID)
        _ = try await store.commitWindowTranscript(ticket: first, text: "第一段完成", rawResult: Data())
        try await store.cancelTranscriptionWindow(ticket: second)
        let retried = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint,
            inputLease: lease, sessionID: first.window.sessionID, expectedGeneration: first.expectedGeneration))
        #expect(retried.window.id == second.window.id)
        _ = try await store.commitWindowTranscript(ticket: retried, text: "第二段重试完成", rawResult: Data())
        try await store.releaseTranscriptionInputLease(lease)
        #expect(await store.audioLeases.isEmpty)
        let unrelated = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        #expect(unrelated.window.epochID != first.window.epochID)
        try await store.cancelTranscriptionWindow(ticket: unrelated)
    }

    @Test func companionsCannotTakeAReservedBackgroundBatch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("reserved-companion".utf8))
        try await prepare(fixture, store: store, fingerprint: fingerprint)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let lease = try await store.acquireTranscriptionInputLease(ticket: first)
        _ = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        #expect(try await store.claimCompanionWindows(after: first, inputLease: lease, maximumCount: 2).isEmpty)
        try await store.cancelTranscriptionWindow(ticket: first)
        try await store.releaseTranscriptionInputLease(lease)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func invalidatedFirstWindowCannotStartABatch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("cancelled-companion".utf8))
        try await prepare(fixture, store: store, fingerprint: fingerprint)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let lease = try await store.acquireTranscriptionInputLease(ticket: first)
        try await store.invalidateTranscriptionWindowAttempt(ticket: first)
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.claimCompanionWindows(after: first, inputLease: lease, maximumCount: 2)
        }
        try await store.cancelTranscriptionWindow(ticket: first)
        try await store.releaseTranscriptionInputLease(lease)
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func independentWindowCommitsAndDeleteHoldFilesUntilSequenceCloses() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("sequence".utf8))
        try await prepare(fixture, store: store, fingerprint: fingerprint)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let lease = try await store.acquireTranscriptionInputLease(ticket: first)
        #expect(lease.contains(first))
        #expect(lease.inputs.count == 2)
        _ = try await store.commitWindowTranscript(ticket: first, text: "第一段", rawResult: Data())
        let second = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, inputLease: lease))
        #expect(second.attemptID != first.attemptID)
        #expect(second.leaseIDs.isEmpty)
        try await store.invalidateTranscriptionWindowAttempt(ticket: second)
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.commitWindowTranscript(ticket: second, text: "迟到结果", rawResult: Data())
        }
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(lease.inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.audioURL.path) })
        try await store.cancelTranscriptionWindow(ticket: second)
        #expect(lease.inputs.allSatisfy { FileManager.default.fileExists(atPath: $0.audioURL.path) })
        try await store.releaseTranscriptionInputLease(lease)
        #expect(lease.inputs.allSatisfy { !FileManager.default.fileExists(atPath: $0.audioURL.path) })
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func releasedSnapshotCannotBypassFileValidationOnAClaim() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("released-sequence".utf8))
        try await prepare(fixture, store: store, fingerprint: fingerprint)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let lease = try await store.acquireTranscriptionInputLease(ticket: first)
        _ = try await store.commitWindowTranscript(ticket: first, text: "第一段", rawResult: Data())
        try await store.releaseTranscriptionInputLease(lease)
        try Data("broken".utf8).write(to: lease.inputs[1].audioURL, options: .atomic)
        await #expect(throws: ArchiveError.missingRecording(lease.inputs[1].envelope.manifest.chunkID)) {
            try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, inputLease: lease)
        }
        #expect(await store.audioLeases.isEmpty)
    }

    @Test func revisionInvalidatesWindowEvenWhileSequenceRetainsOriginals() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        let fingerprint = ContentHash.sha256(Data("revised-sequence".utf8))
        try await prepare(fixture, store: store, fingerprint: fingerprint)
        let first = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let lease = try await store.acquireTranscriptionInputLease(ticket: first)
        let original = try await store.commitWindowTranscript(ticket: first, text: "第一段", rawResult: Data())
        let second = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, inputLease: lease))
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: original.version, spans: [])
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.commitWindowTranscript(ticket: second, text: "旧版本迟到结果", rawResult: Data())
        }
        try await store.cancelTranscriptionWindow(ticket: second)
        try await store.releaseTranscriptionInputLease(lease)
        #expect(await store.audioLeases.isEmpty)
    }

    private func prepare(_ fixture: Fixture, store: ArchiveStore, fingerprint: String) async throws {
        let envelopes = try [fixture.envelope(), fixture.envelope(startFrame: 1600, sequence: 1)]
        for envelope in envelopes { _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store)) }
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3200)
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let windows = envelopes.enumerated().map { index, envelope in
            let m = envelope.manifest
            return ArchiveAnalysisWindow(id: ContentHash.sha256(Data("window-\(m.epochID)-\(index)".utf8)), sessionID: m.sessionID,
                epochID: m.epochID, analysisAnchor: 0, coreFrames: m.frames, contextFrames: m.frames,
                modelCoreFrames: m.frames, modelContextFrames: m.frames,
                sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: envelope.manifestSHA256,
                    audioSHA256: m.audioSHA256, sourceFrames: m.frames)],
                replayInputManifestHashes: envelopes.prefix(index + 1).map(\.manifestSHA256), configurationFingerprint: fingerprint)
        }
        try await store.commitAnalysisBatch(ticket: ticket, windows: windows,
            analyzedCoverage: [FrameRange(start: 0, count: 3200)], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
    }
}
