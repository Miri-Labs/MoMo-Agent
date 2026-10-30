import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ProcessingFailureTests {
    let fingerprint = ContentHash.sha256(Data("failure-isolation".utf8))

    @Test func resumedAnalysisClearsEarlierFailureOnlyAfterItsRangeIsCovered() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
        let first = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        func commit(_ ticket: EpochAnalysisTicket, start: Int64, end: Int64, continuing: Bool = false) async throws {
            let range = try FrameRange(start: start, count: end - start)
            let checkpoint = ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceFrame: end, configurationFingerprint: fingerprint)
            try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [range],
                noSpeechCoverage: [range], checkpoint: checkpoint, waitingForMoreAudio: false, continuing: continuing)
        }
        try await commit(first, start: 0, end: 400, continuing: true)
        try await store.deferEpochAnalysis(ticket: first, code: .recognition, now: Date().addingTimeInterval(3_600))
        let retry = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(retry.checkpoint?.sourceFrame == 400)
        try await commit(retry, start: 400, end: 800)
        let partial = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(partial.epochs.first?.failures.count == 1, "Unprocessed audio must retain its failure.")
        let tail = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        try await commit(tail, start: 800, end: 1_600)
        let reopened = try fixture.store()
        let complete = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(complete.epochs.first?.failures.isEmpty == true)
        #expect(complete.processedDuration == 0.1)
        #expect(try await reopened.processingWaitState(configurationFingerprint: fingerprint) == .idle)
    }

    @Test func deferredFailureSurvivesReopenAndExplicitRetryReleasesOnlyItsScope() async throws {
        let bad = try Fixture(), good = try Fixture()
        defer { bad.remove(); good.remove() }
        let store = try bad.store()
        _ = try await store.commitReceivedChunk(bad.deliver(bad.envelope(), to: store))
        _ = try await store.commitReceivedChunk(good.deliver(good.envelope(), to: store))
        let first = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(first.sessionID == bad.sessionID)
        let now = Date().addingTimeInterval(3_600)
        try await store.deferEpochAnalysis(ticket: first, code: .invalidAudio, now: now)
        #expect(await store.audioLeases.isEmpty)
        let reopened = try bad.store()
        let other = try #require(await reopened.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(other.sessionID == good.sessionID)
        try await reopened.cancelEpochAnalysis(ticket: other)
        if case .retryScheduled(let deadline) = try await reopened.processingWaitState(configurationFingerprint: fingerprint) {
            #expect(abs(deadline.timeIntervalSince(now) - 5) < 0.001)
        } else { Issue.record("The durable retry deadline was not restored.") }
        let coverage = try await reopened.recordingCoverage(sessionID: bad.sessionID, configurationFingerprint: fingerprint)
        #expect(coverage.epochs.first?.failures.first?.frames == first.inputs.first?.envelope.manifest.frames)
        #expect(coverage.epochs.first?.failures.first?.errorCode == ProcessingFailureCode.invalidAudio.rawValue)
        try await reopened.prepareTranscriptionRetry(sessionID: bad.sessionID, expectedGeneration: first.expectedGeneration)
        let retry = try #require(await reopened.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(retry.sessionID == bad.sessionID)
        try await reopened.cancelEpochAnalysis(ticket: retry)
    }

    @Test func damagedClaimIsQuarantinedOnlyWhenTheCallerOptsIn() async throws {
        let bad = try Fixture(), good = try Fixture()
        defer { bad.remove(); good.remove() }
        let store = try bad.store(), envelope = try bad.envelope()
        _ = try await store.commitReceivedChunk(bad.deliver(envelope, to: store))
        _ = try await store.commitReceivedChunk(good.deliver(good.envelope(), to: store))
        let path = try #require(await store.waveformPreparationEntry(chunkID: envelope.manifest.chunkID)).timeline.parts[0]
        let lease = try await store.acquireAudioLease(chunkID: path.manifest.chunkID)
        await store.releaseAudioLease(id: lease.id)
        var data = try Data(contentsOf: lease.audioURL); data[data.count / 2] ^= 1
        try data.write(to: lease.audioURL)
        await #expect(throws: ArchiveError.missingRecording(envelope.manifest.chunkID)) {
            _ = try await store.claimEpochAnalysis(configurationFingerprint: fingerprint)
        }
        let next = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint, isolateLocalFailures: true))
        #expect(next.sessionID == good.sessionID)
        try await store.cancelEpochAnalysis(ticket: next)
        #expect(await store.audioLeases.isEmpty)
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint, sessionID: bad.sessionID) == .unavailableAudio,
            "An unavailable file waits for a verified receipt instead of waking a retry loop.")
        #expect(FileManager.default.fileExists(atPath: lease.audioURL.path), "Failure isolation must preserve the original.")
    }

    @Test func waitingForContextAndActualMissingAudioAreDifferent() async throws {
        let current = try Fixture(), gap = try Fixture()
        defer { current.remove(); gap.remove() }
        let store = try current.store()
        _ = try await store.commitReceivedChunk(current.deliver(current.envelope(), to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: true)
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .awaitingContext)
        let gapStore = try gap.store()
        _ = try await gapStore.commitReceivedChunk(gap.deliver(gap.envelope(startFrame: 1_600, sequence: 1), to: gapStore))
        #expect(try await gapStore.processingWaitState(configurationFingerprint: fingerprint) == .awaitingAudio)
    }

    @Test func deletedAttemptCannotCreateADurableFailure() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await store.commitReceivedChunk(fixture.deliver(fixture.envelope(), to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        _ = try await store.deleteSession(id: fixture.sessionID)
        await #expect(throws: ArchiveError.staleAttempt) { try await store.deferEpochAnalysis(ticket: ticket, code: .invalidAudio) }
        #expect(await store.audioLeases.isEmpty)
        #expect(try await store.processingWaitState(configurationFingerprint: fingerprint) == .idle)
    }
}
