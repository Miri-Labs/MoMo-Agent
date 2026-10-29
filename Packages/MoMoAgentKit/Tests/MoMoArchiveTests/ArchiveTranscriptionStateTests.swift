import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct ArchiveTranscriptionStateTests {
    @Test func deletingAllWordsDoesNotReclassifyRecognizedSpeechAsSilence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let document = try await fixture.transcribe(store)
        #expect(try await store.recordings().first?.transcriptionState == .transcribed)
        _ = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: document.version, spans: [])
        let reopened = try fixture.store()
        #expect(try await reopened.readTranscript(sessionID: fixture.sessionID).spans.isEmpty)
        #expect(try await reopened.recordings().first?.transcriptionState == .completedWithoutText)
    }

    @Test func completedRecognitionWithNoWordsIsNotAVADSilenceResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let manifest = envelope.manifest
        let fingerprint = ContentHash.sha256(Data("empty-recognition".utf8))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: manifest.frames.end)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let window = ArchiveAnalysisWindow(id: ContentHash.sha256(envelope.manifestData),
            sessionID: fixture.sessionID, epochID: fixture.epochID, analysisAnchor: 0,
            coreFrames: manifest.frames, contextFrames: manifest.frames,
            modelCoreFrames: manifest.frames, modelContextFrames: manifest.frames,
            sources: [ArchiveWindowSource(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: manifest.audioSHA256, sourceFrames: manifest.frames)], configurationFingerprint: fingerprint)
        try await store.commitAnalysisBatch(ticket: analysis, windows: [window], analyzedCoverage: [manifest.frames],
            noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        _ = try await store.commitWindowTranscript(ticket: recognition, text: "", rawResult: Data("{}".utf8))
        let reopened = try fixture.store()
        #expect(try await reopened.recordings().first?.transcriptionState == .completedWithoutText)
        let coverage = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(coverage.epochs.first?.noSpeech.isEmpty == true)
        #expect(coverage.epochs.first?.transcribed == [manifest.frames])
    }

    @Test(arguments: [false, true])
    func analyzedPrefixDistinguishesExplicitSilenceFromMissingEvidence(hasExplicitNoSpeech: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try fixture.envelope()
        let manifest = envelope.manifest
        let fingerprint = ContentHash.sha256(Data("explicit-silence".utf8))
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        try await store.markEpochClosed(epochID: fixture.epochID, endFrame: 3200)
        let analysis = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        try await store.commitAnalysisBatch(ticket: analysis, windows: [], analyzedCoverage: [manifest.frames],
            noSpeechCoverage: hasExplicitNoSpeech ? [manifest.frames] : [], checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID,
                epochID: fixture.epochID, sourceFrame: manifest.frames.end, configurationFingerprint: fingerprint), waitingForMoreAudio: true)
        let reopened = try fixture.store()
        #expect(try await reopened.recordings().first?.transcriptionState == (hasExplicitNoSpeech ? .noSpeech : .completedWithoutText))
        let coverage = try await reopened.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint)
        #expect(coverage.epochs.first?.noSpeech == (hasExplicitNoSpeech ? [manifest.frames] : []))
        #expect(coverage.epochs.first?.notReceived == [try FrameRange(start: 1600, count: 1600)])
        #expect(coverage.transcribedDuration == 0)
    }
}
