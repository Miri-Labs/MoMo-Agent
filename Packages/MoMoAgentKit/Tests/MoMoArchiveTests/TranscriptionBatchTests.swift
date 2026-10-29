import Foundation
import Testing
import MoMoContracts
@testable import MoMoArchive

struct TranscriptionBatchTests {
    private let fingerprint = ContentHash.sha256(Data("batch-model".utf8))

    @Test func unpreparedAudioCanCompleteThroughAFiniteBackgroundBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await receive(fixture, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true))
        #expect(batch.windowIDs.isEmpty)
        #expect(batch.totalDuration == 0.1)
        #expect(batch.completedDuration == 0)
        #expect(try await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true) == nil)
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        await #expect(throws: TranscriptionBatchError.incomplete) {
            try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        }
        _ = try await receive(fixture, store: store, sequence: 1)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint) == nil)
        let analysis = try #require(await store.claimTranscriptionBatchAnalysis(execution: execution, configurationFingerprint: fingerprint))
        #expect(analysis.boundary.endFrame == first.manifest.frames.end)
        let window = try await prepare(first, store: store, claimed: analysis)
        let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: execution))
        #expect(ticket.window.id == window.id)
        #expect(try await store.transcriptionBatch(id: batch.id).completedDuration == 0.05)
        _ = try await store.commitWindowTranscript(ticket: ticket, text: "后台也会先分析原音。", rawResult: Data())
        #expect(try await store.claimTranscriptionBatchAnalysis(execution: execution, configurationFingerprint: fingerprint) == nil)
        let completed = try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        #expect(completed.totalDuration == 0.1)
        #expect(completed.completedDuration == completed.totalDuration)
        let later = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true))
        #expect(later.coverage.first?.frozen == [try FrameRange(start: 1600, count: 1600)])
    }

    @Test func rawBatchPauseFencesAnalysisAndResumesAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store = try fixture.store()
        let input = try await receive(fixture, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        let stale = try #require(await store.claimTranscriptionBatchAnalysis(execution: run, configurationFingerprint: fingerprint))
        _ = try await store.finishTranscriptionBatch(execution: run, reason: .systemEndedUnknown)
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.commitAnalysisBatch(ticket: stale, windows: [], analyzedCoverage: [input.manifest.frames],
                noSpeechCoverage: [input.manifest.frames], checkpoint: nil, waitingForMoreAudio: false)
        }
        try await store.cancelEpochAnalysis(ticket: stale)
        store = try fixture.store()
        try await store.recoverInterruptedJobs()
        #expect(try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) == nil)
        #expect(try await store.claimAutomaticWork(configurationFingerprint: fingerprint) == nil)
        _ = try await store.resumeTranscriptionBatch(id: batch.id)
        let resumed = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        let current = try #require(await store.claimTranscriptionBatchAnalysis(execution: resumed, configurationFingerprint: fingerprint))
        try await store.commitAnalysisBatch(ticket: current, windows: [], analyzedCoverage: [input.manifest.frames],
            noSpeechCoverage: [input.manifest.frames], checkpoint: nil, waitingForMoreAudio: false)
        let completed = try await store.finishTranscriptionBatch(execution: resumed, reason: .completed)
        #expect(completed.completedDuration == batch.totalDuration)
        #expect(try await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true) == nil)
    }

    @Test func explicitRawBatchRetriesDeferredAnalysisWithinItsSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let input = try await receive(fixture, store: store)
        let failed = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint, finalizeAvailablePrefixBefore: .distantFuture))
        try await store.deferEpochAnalysis(ticket: failed, code: .recognition, now: Date().addingTimeInterval(3600))
        #expect(try await store.claimEpochAnalysis(configurationFingerprint: fingerprint, finalizeAvailablePrefixBefore: .distantFuture) == nil)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        await #expect(throws: ArchiveError.invalidQuery) {
            try await store.claimEpochAnalysis(configurationFingerprint: fingerprint,
                selectedEpochID: input.manifest.epochID, processingRange: FrameRange(start: 0, count: 3200), batchExecution: run)
        }
        let retry = try #require(await store.claimTranscriptionBatchAnalysis(execution: run, configurationFingerprint: fingerprint))
        #expect(retry.inputIdentity == failed.inputIdentity)
        try await store.cancelEpochAnalysis(ticket: retry)
    }

    @Test func unpreparedBatchHandlesReceivedGapsAndDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        _ = try await receive(fixture, store: store)
        _ = try await receive(fixture, store: store, sequence: 2)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint, includingUnpreparedAudio: true))
        #expect(batch.totalDuration == 0.2)
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        for start: Int64 in [0, 3200] {
            let analysis = try #require(await store.claimTranscriptionBatchAnalysis(execution: run, configurationFingerprint: fingerprint))
            let frames = try FrameRange(start: start, count: 1600)
            #expect(analysis.boundary.endFrame == frames.end)
            try await store.commitAnalysisBatch(ticket: analysis, windows: [], analyzedCoverage: [frames],
                noSpeechCoverage: [frames], checkpoint: nil, waitingForMoreAudio: false)
        }
        #expect(try await store.transcriptionBatch(id: batch.id).completedDuration == 0.2)
        _ = try await store.deleteSession(id: fixture.sessionID)
        #expect(try await store.claimTranscriptionBatchAnalysis(execution: run, configurationFingerprint: fingerprint) == nil)
        let completed = try await store.finishTranscriptionBatch(execution: run, reason: .completed)
        #expect(completed.completedDuration == 0)
        #expect(completed.removedDuration == 0.2)
    }

    @Test func explicitBatchCanRetryAnAutomaticallyDeferredWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try await receive(fixture, store: store)
        let window = try await prepare(envelope, store: store)
        let failed = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        try await store.deferTranscriptionWindow(ticket: failed, code: .recognition, now: Date().addingTimeInterval(3_600))
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) == nil)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        let retry = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: execution))
        #expect(retry.window.id == window.id)
        _ = try await store.commitWindowTranscript(ticket: retry, text: "恢复的文字。", rawResult: Data())
        #expect(try await store.finishTranscriptionBatch(execution: execution, reason: .completed).state == .completed)
        #expect(try await store.recordingCoverage(sessionID: fixture.sessionID, configurationFingerprint: fingerprint).epochs.flatMap(\.failures).isEmpty)
    }

    @Test func activeBatchRemainsDiscoverableBeyondRecentHistoryLimit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let input = try await receive(fixture, store: store)
        _ = try await prepare(input, store: store)
        let first = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let run = try await store.beginTranscriptionBatch(id: first.id, origin: .continuedProcessing)
        // A known request rejection is recoverable, unlike an unknown system end after admission.
        #expect(try await store.finishTranscriptionBatch(execution: run, reason: .interrupted).state == .ready)
        for sequence in 1...51 {
            let envelope = try await receive(fixture, store: store, sequence: Int64(sequence))
            _ = try await prepare(envelope, store: store)
            let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
            let execution = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
            let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: execution))
            _ = try await store.commitWindowTranscript(ticket: ticket, text: "后续资料。", rawResult: Data("{}".utf8))
            _ = try await store.finishTranscriptionBatch(execution: execution, reason: .completed)
        }
        #expect(try await !store.transcriptionBatches().contains { $0.id == first.id })
        #expect(try await store.activeTranscriptionBatches().map(\.id) == [first.id])
    }

    @Test func frozenDenominatorExcludesUnpreparedTailAndLaterReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let first = try await receive(fixture, store: store)
        let tail = try await receive(fixture, store: store, sequence: 1)
        let window = try await prepare(first, store: store)
        let id = UUID()
        let batch = try #require(await store.freezeTranscriptionBatch(id: id, configurationFingerprint: fingerprint))
        #expect(batch.windowIDs == [window.id])
        #expect(batch.coverage.first?.frozen == [first.manifest.frames])
        #expect(abs(batch.totalDuration - 0.1) < 0.000001)
        #expect(abs(batch.completedDuration - 0.05) < 0.000001)
        _ = try await receive(fixture, store: store, sequence: 2)
        let nextWindow = try await prepare(tail, store: store)
        #expect(try await store.transcriptionBatch(id: id) == batch)
        #expect(try await store.freezeTranscriptionBatch(id: id, configurationFingerprint: fingerprint) == batch)
        let next = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        #expect(next.windowIDs == [nextWindow.id])
        #expect(next.coverage.first?.frozen == [tail.manifest.frames])
        #expect(abs(next.totalDuration - 0.1) < 0.000001)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) == nil)
        let run = try await store.beginTranscriptionBatch(id: id, origin: .foreground)
        let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run))
        #expect(ticket.window.id == window.id)
        _ = try await store.commitWindowTranscript(ticket: ticket, text: "只处理本批。", rawResult: Data("{}".utf8))
        let complete = try await store.finishTranscriptionBatch(execution: run, reason: .completed)
        #expect(complete.state == .completed)
        #expect(complete.completedDuration == complete.totalDuration)
        #expect(try await store.transcriptionBatch(id: next.id).state == .ready)
    }

    @Test(arguments: [TranscriptionBatchEndReason.userPaused, .systemEndedUnknown])
    func pauseSurvivesRestartAndEveryOrdinaryClaimPath(reason: TranscriptionBatchEndReason) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try await receive(fixture, store: store)
        _ = try await prepare(envelope, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .continuedProcessing)
        let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run))
        let paused = try await store.finishTranscriptionBatch(execution: run, reason: reason)
        #expect(paused.state == .paused)
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.commitWindowTranscript(ticket: ticket, text: "迟到。", rawResult: Data("{}".utf8))
        }
        try await store.cancelTranscriptionWindow(ticket: ticket)
        let reopened = try fixture.store()
        try await reopened.recoverInterruptedJobs()
        #expect(try await reopened.transcriptionBatch(id: batch.id).state == .paused)
        #expect(try await reopened.transcriptionBatch(id: batch.id).endReason == reason)
        #expect(try await reopened.claimTranscriptionWindow(configurationFingerprint: fingerprint) == nil)
        #expect(try await reopened.claimAnalysisJob(configurationHash: "legacy-model") == nil)
        await #expect(throws: TranscriptionBatchError.paused) {
            try await reopened.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        }
        // A second model must not bypass a paused source interval with a different window ID.
        let other = ContentHash.sha256(Data("another-model".utf8))
        _ = try await prepare(envelope, store: reopened, configuration: other)
        #expect(try await reopened.claimTranscriptionWindow(configurationFingerprint: other) == nil)
        #expect(try await reopened.freezeTranscriptionBatch(configurationFingerprint: other) == nil)
        _ = try await reopened.resumeTranscriptionBatch(id: batch.id)
        let resumed = try await reopened.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        let current = try #require(await reopened.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: resumed))
        _ = try await reopened.commitWindowTranscript(ticket: current, text: "继续。", rawResult: Data("{}".utf8))
        #expect(try await reopened.finishTranscriptionBatch(execution: resumed, reason: .completed).state == .completed)
    }

    @Test func backgroundExpiryResumesAndOldEndEventCannotStopNewExecution() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let envelope = try await receive(fixture, store: store)
        _ = try await prepare(envelope, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let first = try await store.beginTranscriptionBatch(id: batch.id, origin: .backgroundProcessing)
        #expect(try await store.beginTranscriptionBatch(id: batch.id, executionID: first.executionID, origin: first.origin) == first)
        let old = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: first))
        await #expect(throws: TranscriptionBatchError.incomplete) { try await store.finishTranscriptionBatch(execution: first, reason: .completed) }
        #expect(try await store.finishTranscriptionBatch(execution: first, reason: .backgroundExpired).state == .ready)
        let second = try await store.beginTranscriptionBatch(id: batch.id, origin: .backgroundProcessing)
        #expect(try await store.finishTranscriptionBatch(execution: first, reason: .userPaused).execution == second)
        let current = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: second))
        await #expect(throws: ArchiveError.staleAttempt) {
            try await store.commitWindowTranscript(ticket: old, text: "旧运行。", rawResult: Data("{}".utf8))
        }
        // Old reader cleanup must not clear the new ticket's durable attempt.
        try await store.cancelTranscriptionWindow(ticket: old)
        _ = try await store.commitWindowTranscript(ticket: current, text: "新运行。", rawResult: Data("{}".utf8))
        let result = try await store.finishTranscriptionBatch(execution: second, reason: .completed)
        #expect(try await store.finishTranscriptionBatch(execution: second, reason: .systemEndedUnknown) == result)
        #expect(result.state == .completed)
        #expect(result.completedDuration == result.totalDuration)
    }

    @Test(arguments: [TranscriptionBatchOrigin.foreground, .backgroundProcessing, .continuedProcessing])
    func interruptedExecutionRecoveryPreservesOriginPolicy(origin: TranscriptionBatchOrigin) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var store = try fixture.store()
        let envelope = try await receive(fixture, store: store)
        _ = try await prepare(envelope, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: origin)
        _ = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run))
        store = try fixture.store()
        try await store.recoverInterruptedJobs()
        let recovered = try await store.transcriptionBatch(id: batch.id)
        #expect(recovered.state == (origin == .continuedProcessing ? .paused : .ready))
        #expect(recovered.endReason == (origin == .continuedProcessing ? .systemEndedUnknown : .interrupted))
        #expect(recovered.execution == nil)
        try await store.recoverInterruptedJobs()
        #expect(try await store.transcriptionBatch(id: batch.id) == recovered)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) == nil)
        await #expect(throws: TranscriptionBatchError.staleExecution) {
            try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run)
        }
    }

    @Test func deletingOneMemberRetainsDenominatorAndOtherMembersProgress() async throws {
        let first = try Fixture(), second = try Fixture()
        defer { first.remove(); second.remove() }
        let store = try first.store()
        let firstInput = try await receive(first, store: store)
        _ = try await prepare(firstInput, store: store)
        let secondInput = try await receive(second, store: store)
        _ = try await prepare(secondInput, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        let deleted = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run))
        #expect(deleted.window.sessionID == first.sessionID)
        _ = try await store.deleteSession(id: first.sessionID)
        let changed = try await store.transcriptionBatch(id: batch.id)
        #expect(changed.totalDuration == batch.totalDuration)
        #expect(abs(changed.removedDuration - 0.1) < 0.000001)
        #expect(FileManager.default.fileExists(atPath: deleted.inputs[0].audioURL.path))
        try await store.cancelTranscriptionWindow(ticket: deleted)
        #expect(!FileManager.default.fileExists(atPath: deleted.inputs[0].audioURL.path))
        let survivor = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run))
        #expect(survivor.window.sessionID == second.sessionID)
        _ = try await store.commitWindowTranscript(ticket: survivor, text: "保留的资料。", rawResult: Data("{}".utf8))
        let finished = try await store.finishTranscriptionBatch(execution: run, reason: .completed)
        #expect(finished.state == .completed)
        #expect(abs(finished.completedDuration + finished.removedDuration - finished.totalDuration) < 0.000001)
    }

    @Test func revisionRejectsOldAttemptWithoutUnpausingOrReplacingFrozenInputs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let firstInput = try await receive(fixture, store: store)
        _ = try await prepare(firstInput, store: store)
        let initial = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint))
        let original = try await store.commitWindowTranscript(ticket: initial, text: "周一。", rawResult: Data("{}".utf8))
        let secondInput = try await receive(fixture, store: store, sequence: 1)
        _ = try await prepare(secondInput, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        let old = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: run))
        let span = try #require(original.spans.first)
        let edited = TranscriptSpan(id: span.id, chunkID: span.chunkID, frames: span.frames, text: "周二。", sourceRanges: span.sourceRanges)
        let revision = try await store.reviseTranscript(sessionID: fixture.sessionID, expectedVersion: original.version, spans: [edited])
        await #expect(throws: ArchiveError.staleAttempt) { try await store.commitWindowTranscript(ticket: old, text: "旧结果。", rawResult: Data("{}".utf8)) }
        try await store.cancelTranscriptionWindow(ticket: old)
        _ = try await store.finishTranscriptionBatch(execution: run, reason: .userPaused)
        #expect(try await store.transcriptionBatch(id: batch.id).windowIDs == batch.windowIDs)
        #expect(try await store.transcriptionBatch(id: batch.id).totalDuration == batch.totalDuration)
        #expect(try await store.claimTranscriptionWindow(configurationFingerprint: fingerprint) == nil)
        _ = try await store.resumeTranscriptionBatch(id: batch.id)
        let resumed = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        let ticket = try #require(await store.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: resumed))
        #expect(ticket.expectedGeneration == revision.generation)
        let document = try await store.commitWindowTranscript(ticket: ticket, text: "后续录音。", rawResult: Data("{}".utf8))
        #expect(document.spans.map(\.text) == ["周二。", "后续录音。"])
    }

    @Test func silenceAloneDoesNotCreateAnEmptyContinuedProcessingBatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let input = try await receive(fixture, store: store)
        let ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        try await store.commitAnalysisBatch(ticket: ticket, windows: [], analyzedCoverage: [input.manifest.frames],
            noSpeechCoverage: [input.manifest.frames], checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID,
                epochID: fixture.epochID, sourceFrame: input.manifest.frames.end, configurationFingerprint: fingerprint), waitingForMoreAudio: true)
        #expect(try await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint) == nil)
        #expect(try await store.transcriptionBatches().isEmpty)
        let voiced = try Fixture()
        defer { voiced.remove() }
        let voiceInput = try await receive(voiced, store: store)
        _ = try await prepare(voiceInput, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        #expect(batch.coverage.count == 2)
        #expect(abs(batch.totalDuration - 0.2) < 0.000001)
        #expect(abs(batch.completedDuration - 0.15) < 0.000001)
    }

    @Test func deletingEveryMemberReportsRemovedRatherThanTranscribedDuration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let input = try await receive(fixture, store: store)
        _ = try await prepare(input, store: store)
        let batch = try #require(await store.freezeTranscriptionBatch(configurationFingerprint: fingerprint))
        let run = try await store.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        _ = try await store.finishTranscriptionBatch(execution: run, reason: .userPaused)
        _ = try await store.deleteSession(id: fixture.sessionID)
        let reopened = try fixture.store()
        try await reopened.recoverInterruptedJobs()
        let removed = try await reopened.transcriptionBatch(id: batch.id)
        #expect(removed.state == .paused)
        #expect(removed.totalDuration == batch.totalDuration)
        #expect(removed.removedDuration == batch.totalDuration)
        #expect(removed.completedDuration == 0)
        _ = try await reopened.resumeTranscriptionBatch(id: batch.id)
        let resumed = try await reopened.beginTranscriptionBatch(id: batch.id, origin: .foreground)
        #expect(try await reopened.claimTranscriptionWindow(configurationFingerprint: fingerprint, batchExecution: resumed) == nil)
        let complete = try await reopened.finishTranscriptionBatch(execution: resumed, reason: .completed)
        #expect(complete.state == .completed)
        #expect(complete.completedDuration == 0)
        #expect(complete.removedDuration == complete.totalDuration)
    }

    @Test func openAnalysisExtendsPastMemoizedMultiChunkTailToClaimNewlyArrivedChunks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try fixture.store()
        let chunkFrames: Int64 = 960_000
        for sequence in 0..<3 {
            let envelope = try fixture.envelope(startFrame: Int64(sequence) * chunkFrames, frameCount: chunkFrames, sequence: Int64(sequence))
            _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        }
        // First pass advances checkpoint to 222,912 so the next pass at start=222,912 has through = 2,142,912, spanning chunks 0..2 [0..<2,880,000].
        let initial = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        let initialRange = try FrameRange(start: 0, count: 222_912)
        try await store.commitAnalysisBatch(
            ticket: initial,
            windows: [],
            analyzedCoverage: [initialRange],
            noSpeechCoverage: [initialRange],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceFrame: initialRange.end, configurationFingerprint: fingerprint),
            waitingForMoreAudio: false
        )
        let second = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(second.inputs.count == 3)
        // Advance checkpoint to 414,912 while memoizing the 3-chunk tailInputs [0..<2,880,000] with waitingForMoreAudio=true,
        // so start + 1,920,000 = 2,334,912 < 2,880,000 on the next open claim.
        let secondRange = try FrameRange(start: initialRange.end, count: 192_000)
        try await store.commitAnalysisBatch(
            ticket: second,
            windows: [],
            analyzedCoverage: [secondRange],
            noSpeechCoverage: [secondRange],
            checkpoint: ArchiveCheckpoint(sessionID: fixture.sessionID, epochID: fixture.epochID, sourceFrame: secondRange.end, configurationFingerprint: fingerprint),
            waitingForMoreAudio: true
        )
        // With no new audio beyond chunk 2, open claim is still suppressed because identity matches.
        #expect(try await store.claimEpochAnalysis(configurationFingerprint: fingerprint) == nil)
        // Once chunk 3 arrives at [2,880,000..<3,840,000], open claim must extend past the memoized 3-chunk tail to include chunk 3.
        let fourth = try fixture.envelope(startFrame: 3 * chunkFrames, frameCount: chunkFrames, sequence: 3)
        _ = try await store.commitReceivedChunk(fixture.deliver(fourth, to: store))
        let next = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint))
        #expect(next.inputs.count == 4)
        #expect(next.inputs.last?.envelope.manifest.frames.end == 4 * chunkFrames)
        try await store.cancelEpochAnalysis(ticket: next)
    }

    private func receive(_ fixture: Fixture, store: ArchiveStore, sequence: Int64 = 0) async throws -> ManifestEnvelope {
        let envelope = try fixture.envelope(startFrame: sequence * 1600, sequence: sequence)
        _ = try await store.commitReceivedChunk(fixture.deliver(envelope, to: store))
        return envelope
    }

    private func prepare(_ envelope: ManifestEnvelope, store: ArchiveStore, configuration: String? = nil,
                         claimed: EpochAnalysisTicket? = nil) async throws -> ArchiveAnalysisWindow {
        let fingerprint = configuration ?? self.fingerprint
        let manifest = envelope.manifest
        let ticket: EpochAnalysisTicket
        if let claimed { ticket = claimed }
        else { ticket = try #require(await store.claimEpochAnalysis(configurationFingerprint: fingerprint)) }
        #expect(ticket.epochID == manifest.epochID)
        let core = try FrameRange(start: manifest.frames.start + 400, count: 800)
        let window = try ArchiveAnalysisWindow(id: ContentHash.sha256(Data((envelope.manifestSHA256 + fingerprint).utf8)),
            sessionID: manifest.sessionID, epochID: manifest.epochID, analysisAnchor: manifest.frames.start,
            coreFrames: core, contextFrames: manifest.frames,
            modelCoreFrames: FrameRange(start: 400, count: 800), modelContextFrames: FrameRange(start: 0, count: 1600),
            sources: [ArchiveWindowSource(chunkID: manifest.chunkID, manifestSHA256: envelope.manifestSHA256,
                audioSHA256: manifest.audioSHA256, sourceFrames: manifest.frames)], configurationFingerprint: fingerprint)
        try await store.commitAnalysisBatch(ticket: ticket, windows: [window], analyzedCoverage: [manifest.frames],
            noSpeechCoverage: [FrameRange(start: manifest.frames.start, count: 400), FrameRange(start: core.end, count: 400)],
            checkpoint: ArchiveCheckpoint(sessionID: manifest.sessionID, epochID: manifest.epochID,
                sourceFrame: manifest.frames.end, configurationFingerprint: fingerprint), waitingForMoreAudio: !ticket.epochClosed)
        return window
    }
}
