import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct AnalysisUpgradeTests {
    let old = ContentHash.sha256(Data("old-detector".utf8))
    let new = ContentHash.sha256(Data("new-detector".utf8))

    @Test func completedHistoryIncludingOldSilenceDoesNotRunAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: old))
        let window = try makeWindow(envelope, start: 0, count: 800)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [FrameRange(start: 800, count: 800)],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceFrame: 1600, configurationFingerprint: old), waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: old))
        let original = try await store.commitWindowTranscript(ticket: recognition, text: "已保存的正文", rawResult: Data("{}".utf8))
        try await store.preserveCompletedAnalysis(from: old, to: new)
        try await store.preserveCompletedAnalysis(from: old, to: new)
        let coverage = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: new)
        #expect(coverage.processedDuration == 0.1)
        #expect(coverage.epochs.first?.noSpeech == [try FrameRange(start: 800, count: 800)])
        #expect(try await store.claimAutomaticWork(configurationFingerprint: new) == nil)
        let unchanged = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(try WireJSON.encode(unchanged) == WireJSON.encode(original))
        #expect(try await store.freezeTranscriptionBatch(configurationFingerprint: new, includingUnpreparedAudio: true) == nil)
        let next = try fixture.envelope(startFrame: 1600, sequence: 1)
        _ = try await store.commitReceivedChunk(fixture.deliver(next, to: store))
        let continuation = try #require(await store.claimEpochAnalysis(configurationFingerprint: new))
        #expect(continuation.checkpoint?.sourceFrame == 1600)
        #expect(continuation.inputs.map(\.envelope.manifest.chunkID) == [next.manifest.chunkID])
        try await store.cancelEpochAnalysis(ticket: continuation)
    }

    @Test func unfinishedBatchKeepsItsScopeAndCanPrepareAfterUpgrade() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: old))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [makeWindow(envelope, start: 0, count: 1600)],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: old))
        try await store.preserveCompletedAnalysis(from: old, to: new)
        let updated = try await store.transcriptionBatch(id: batch.id)
        #expect(updated.configurationFingerprint == new)
        #expect(updated.coverage.map(\.frozen) == batch.coverage.map(\.frozen))
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        let prepared = try #require(await store.claimTranscriptionBatchAnalysis(execution: execution, configurationFingerprint: new))
        #expect(prepared.boundary.endFrame == 1600)
        try await store.cancelEpochAnalysis(ticket: prepared)
    }

    @Test(arguments: [false, true])
    func historySurvivesSuccessiveOrSkippedPolicyVersions(skipIntermediate: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: old))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [makeWindow(envelope, start: 0, count: 800)],
            analyzedCoverage: [envelope.manifest.frames], noSpeechCoverage: [FrameRange(start: 800, count: 800)],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceFrame: 1600, configurationFingerprint: old), waitingForMoreAudio: false)
        let recognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: old))
        let original = try await store.commitWindowTranscript(ticket: recognition, text: "保留历史", rawResult: Data("{}".utf8))
        let latest = ContentHash.sha256(Data("selective-policy".utf8))
        if !skipIntermediate { try await store.preserveCompletedAnalysis(from: old, to: new) }
        // The latest policy carries newest results first, then installations that skipped that release.
        for previous in [new, old] { try await store.preserveCompletedAnalysis(from: previous, to: latest) }
        #expect(try await store.claimAutomaticWork(configurationFingerprint: latest) == nil)
        let coverage = try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: latest)
        #expect(coverage.processedDuration == coverage.receivedDuration)
        #expect(coverage.epochs.first?.noSpeech == [try FrameRange(start: 800, count: 800)])
        let unchanged = try await store.readTranscript(sessionID: fixture.sessionID)
        #expect(try WireJSON.encode(unchanged) == WireJSON.encode(original))
    }

    @Test func unfinishedBatchReconcilesWithAlreadyCompletedTargetAnalysis() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        // Target fingerprint (new) already completed analysis and transcription with its own VAD window boundaries.
        let newTicket = try #require(await store.claimEpochAnalysis(configurationFingerprint: new))
        let m = envelope.manifest, newRange = try FrameRange(start: 0, count: 800)
        let newWindow = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(m.chunkID)/new/0".utf8)), sessionID: m.sessionID,
            epochID: m.epochID, analysisAnchor: 0, coreFrames: newRange, contextFrames: newRange,
            modelCoreFrames: newRange, modelContextFrames: newRange,
            sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: newRange)], configurationFingerprint: new)
        try await store.commitAnalysisBatch(ticket: newTicket, windows: [newWindow],
            analyzedCoverage: [m.frames], noSpeechCoverage: [FrameRange(start: 800, count: 800)],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceFrame: 1600, configurationFingerprint: new), waitingForMoreAudio: false)
        let newRecognition = try #require(await store.claimTranscriptionWindow(configurationFingerprint: new))
        _ = try await store.commitWindowTranscript(ticket: newRecognition, text: "已完成的新版转写", rawResult: Data("{}".utf8))

        // An older fingerprint (old) freezes a batch with different window/silence boundaries.
        let oldTicket = try #require(await store.claimEpochAnalysis(configurationFingerprint: old))
        try await store.commitAnalysisBatch(ticket: oldTicket, windows: [makeWindow(envelope, start: 400, count: 800)],
            analyzedCoverage: [m.frames], noSpeechCoverage: [FrameRange(start: 0, count: 400), FrameRange(start: 1200, count: 400)],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID,
                sourceFrame: 1600, configurationFingerprint: old), waitingForMoreAudio: false)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: old, includingUnpreparedAudio: true))

        try await store.preserveCompletedAnalysis(from: old, to: new)
        let updated = try await store.transcriptionBatch(id: batch.id)
        #expect(updated.configurationFingerprint == new)
        #expect(updated.coverage.map(\.frozen) == batch.coverage.map(\.frozen))
        #expect(updated.completedDuration == updated.totalDuration)
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: new, batchExecution: execution) == nil)
        #expect(try await store.claimTranscriptionBatchAnalysis(execution: execution, configurationFingerprint: new) == nil)
        let completed = try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        #expect(completed.state == .completed)
    }

    @Test func partialUnpreparedBatchCompletesWhenWindowsStraddleAndBridgeBoundaries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store(), envelope = try fixture.envelope()
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        let m = envelope.manifest

        // Earlier speech windows 0..300 and 1300..1600 already completed; 300..1300 is unprepared.
        let initial = try #require(await store.claimEpochAnalysis(configurationFingerprint: new))
        let wLeft = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(m.chunkID)/left".utf8)), sessionID: m.sessionID,
            epochID: m.epochID, analysisAnchor: 0, coreFrames: try FrameRange(start: 0, count: 350),
            contextFrames: try FrameRange(start: 0, count: 350), modelCoreFrames: try FrameRange(start: 0, count: 350),
            modelContextFrames: try FrameRange(start: 0, count: 350),
            sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: try FrameRange(start: 0, count: 350))], configurationFingerprint: new)
        let wRight = ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(m.chunkID)/right".utf8)), sessionID: m.sessionID,
            epochID: m.epochID, analysisAnchor: 0, coreFrames: try FrameRange(start: 1250, count: 350),
            contextFrames: try FrameRange(start: 1250, count: 350), modelCoreFrames: try FrameRange(start: 1250, count: 350),
            modelContextFrames: try FrameRange(start: 1250, count: 350),
            sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: try FrameRange(start: 1250, count: 350))], configurationFingerprint: new)
        try await store.commitAnalysisBatch(ticket: initial, windows: [wLeft, wRight],
            analyzedCoverage: [m.frames], noSpeechCoverage: [FrameRange(start: 350, count: 900)],
            checkpoint: nil, waitingForMoreAudio: false)
        while let win = try await store.claimTranscriptionWindow(configurationFingerprint: new) {
            _ = try await store.commitWindowTranscript(ticket: win, text: "已有两侧转写", rawResult: Data("{}".utf8))
        }

        // Old fingerprint had narrower completed windows (0..300 and 1300..1600) and froze unprepared 300..1300.
        let oldInitial = try #require(await store.claimEpochAnalysis(configurationFingerprint: old))
        try await store.commitAnalysisBatch(ticket: oldInitial,
            windows: [makeWindow(envelope, start: 0, count: 300), makeWindow(envelope, start: 1300, count: 300)],
            analyzedCoverage: [FrameRange(start: 0, count: 300), FrameRange(start: 1300, count: 300)],
            noSpeechCoverage: [], checkpoint: nil, waitingForMoreAudio: false)
        while let win = try await store.claimTranscriptionWindow(configurationFingerprint: old) {
            _ = try await store.commitWindowTranscript(ticket: win, text: "旧版转写", rawResult: Data("{}".utf8))
        }
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: old, includingUnpreparedAudio: true))
        #expect(batch.coverage.first?.frozen == [try FrameRange(start: 300, count: 1000)])

        // Upgrade reconciles batch (frozen 300..1300) against straddling completed windows 0..350 & 1250..1600 + silence 350..1250.
        try await store.preserveCompletedAnalysis(from: old, to: new)
        let updated = try await store.transcriptionBatch(id: batch.id)
        #expect(updated.totalDuration == batch.totalDuration)
        #expect(updated.completedDuration == updated.totalDuration)
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: new, batchExecution: execution) == nil)
        #expect(try await store.claimTranscriptionBatchAnalysis(execution: execution, configurationFingerprint: new) == nil)
        let completed = try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        #expect(completed.state == .completed)
    }

    private func makeWindow(_ envelope: ManifestEnvelope, start: Int64, count: Int64) throws -> ArchiveAnalysisWindow {
        let m = envelope.manifest, range = try FrameRange(start: start, count: count)
        return ArchiveAnalysisWindow(id: ContentHash.sha256(Data("\(m.chunkID)/\(start)".utf8)), sessionID: m.sessionID,
            epochID: m.epochID, analysisAnchor: 0, coreFrames: range, contextFrames: range,
            modelCoreFrames: range, modelContextFrames: range,
            sources: [ArchiveWindowSource(chunkID: m.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: m.audioSHA256, sourceFrames: range)], configurationFingerprint: old)
    }
}
