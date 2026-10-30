import CoreML
import Foundation
import os
import Testing
@testable import MoMoArchive
import MoMoContracts
import MoMoSpeech
@testable import PhonePipelineReplay

@Suite(.serialized)
struct PipelineTests {
    enum Mode: CaseIterable, Sendable { case overlap, pause, backgroundExpiry, serial }

    @Test(arguments: [false, true])
    func receivedArchiveUsesTwoWindowBatchAndRecoversAfterPause(pause: Bool) async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("native-batch-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let voice = model.appendingPathComponent("test_wavs/zh.wav")
        let silence = try PhoneTranscriptionFixture.makeSilence(directory: root.appendingPathComponent("capture"))
        let recording = try await TranscriptionIntegrationScenario.ingest(
            [voice, silence, voice] + Array(repeating: silence, count: 20), archive: archive, closeEpoch: false)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = OSAllocatedUnfairLock(initialState: true), timedOut = OSAllocatedUnfairLock(initialState: false)
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            recognitionBackend: .sherpaCoreML,
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } },
            onEvent: { event in
                guard pause, case .nativeDecodeStarted = event,
                      first.withLock({ value in defer { value = false }; return value }) else { return }
                entered.signal()
                if release.wait(timeout: .now() + 15) != .success { timedOut.withLock { $0 = true } }
            })
        defer { release.signal() }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let run = Task { await coordinator.runUntilIdle() }
        if pause {
            #expect(await Task.detached { waitForPipelineEntry(entered) }.value)
            try await coordinator.pauseByUser()
            // Pausing fences both results before the native batch returns.
            await #expect(throws: ArchiveError.missingTranscript(recording.sessionID)) {
                try await archive.readTranscript(sessionID: recording.sessionID)
            }
            release.signal()
            #expect(await run.value.snapshot.phase == .paused)
            try await coordinator.resumeByUser()
        }
        let report = pause ? await coordinator.runUntilIdle() : await run.value
        // The current recording remains open; only its undecided VAD tail waits.
        #expect(report.snapshot.phase == .waitingForContext)
        #expect(!timedOut.withLock { $0 })
        #expect(diagnostics.withLock { $0.contains { $0.operation == .transcribe && $0.outputWindowCount == 2 && $0.outcome == .completed } })
        let transcript = try await archive.readTranscript(sessionID: recording.sessionID)
        #expect(transcript.spans.count == 2)
        #expect(transcript.spans.allSatisfy { !$0.text.isEmpty })
        #expect(report.snapshot.completedWindows == 2)
    }

    @Test func corruptCompanionRetriesIndividuallyAndPreservesHealthyWindow() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("batch-corruption-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let voice = model.appendingPathComponent("test_wavs/zh.wav")
        let silence = try PhoneTranscriptionFixture.makeSilence(directory: root.appendingPathComponent("capture"))
        let recording = try await TranscriptionIntegrationScenario.ingest(
            [voice, silence, voice] + Array(repeating: silence, count: 20), archive: archive, closeEpoch: false)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            recognitionBackend: .sherpaCoreML)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let mutated = OSAllocatedUnfairLock(initialState: false)
        await coordinator.observeClaims { kind, _ in
            guard kind == .transcription, mutated.withLock({ value in
                guard !value else { return false }; value = true; return true
            }) else { return }
            do {
                let url = recording.audioURLs[2]
                var bytes = try Data(contentsOf: url)
                bytes[bytes.count / 2] ^= 1
                try bytes.write(to: url)
            } catch { Issue.record("Could not corrupt the companion fixture: \(error)") }
        }
        let report = await coordinator.runUntilIdle()
        #expect(mutated.withLock { $0 })
        #expect(report.snapshot.phase == .audioUnavailable)
        #expect(report.snapshot.completedWindows == 1)
        let transcript = try await archive.readTranscript(sessionID: recording.sessionID)
        #expect(transcript.spans.count == 1)
        #expect(!transcript.spans[0].text.isEmpty)
        let coverage = try await archive.recordingCoverage(sessionID: recording.sessionID,
            configurationFingerprint: engine.configurationFingerprint)
        #expect(coverage.epochs.contains { !$0.unavailableAudio.isEmpty })
        await coordinator.suspendForSystem()
    }

    #if DEBUG
    @Test func noSpeechReviewPreservesUserPauseAndExistingTextAcrossRestart() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("no-speech-review-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"),
            directory: root.appendingPathComponent("capture"))
        let anchor = Date().addingTimeInterval(-172_800)
        let audio = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: anchor)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration())
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let initial = await coordinator.runUntilIdle()
        #expect(initial.snapshot.phase == .idle)
        let original = try await archive.readTranscript(sessionID: audio.sessionID)
        #expect(!original.spans.isEmpty)
        try await coordinator.pauseByUser()
        try engine.setVoiceActivityThreshold(0.25)
        let seconds = try await coordinator.reviewNoSpeech(in: DateInterval(start: anchor, duration: 120))
        #expect(seconds > 0)
        #expect(await coordinator.snapshot().phase == .paused)
        #expect(try await archive.readTranscript(sessionID: audio.sessionID).spans == original.spans)
        let restarted = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        #expect(await restarted.snapshot().phase == .paused)
        try await restarted.resumeByUser()
        let completed = await restarted.runUntilIdle()
        #expect(completed.snapshot.phase == .idle)
        let reviewed = try await archive.readTranscript(sessionID: audio.sessionID)
        #expect(original.spans.allSatisfy { reviewed.spans.contains($0) })
        #expect(try await archive.searchTranscripts(query: "开放时间").count == 1)
    }

    #endif

    @Test func userRequestedContinuationHandsOffTheFiniteBatchBeforeNativeReturns() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("user-continuation-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"), directory: root.appendingPathComponent("capture"))
        _ = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = OSAllocatedUnfairLock(initialState: true), timedOut = OSAllocatedUnfairLock(initialState: false)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(), onEvent: { event in
            guard case .nativeDecodeStarted = event, first.withLock({ value in defer { value = false }; return value }) else { return }
            entered.signal()
            if release.wait(timeout: .now() + 15) != .success { timedOut.withLock { $0 = true } }
            returned.withLock { $0 = true }
        })
        defer { release.signal() }
        while let ticket = try await archive.claimEpochAnalysis(configurationFingerprint: engine.configurationFingerprint) {
            do {
                let result = try await engine.prepare(inputs: ticket.inputs.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) },
                    resume: ticket.checkpoint.map { SpeechCheckpoint(sessionID: $0.sessionID, epochID: $0.epochID, sourceFrame: $0.sourceFrame,
                        configurationFingerprint: $0.configurationFingerprint) }, epochClosed: ticket.epochClosed, attempt: SpeechAttempt(id: ticket.attemptID))
                let windows = result.windows.map { window in
                    ArchiveAnalysisWindow(id: window.id, sessionID: window.sessionID, epochID: window.epochID,
                        analysisAnchor: window.analysisAnchor, coreFrames: window.coreFrames, contextFrames: window.contextFrames,
                        modelCoreFrames: window.modelCoreFrames, modelContextFrames: window.modelContextFrames,
                        sources: window.sources.map { .init(chunkID: $0.chunkID, manifestSHA256: $0.manifestSHA256,
                            audioSHA256: $0.audioSHA256, sourceFrames: $0.sourceFrames) }, replayInputManifestHashes: window.replayInputManifestHashes,
                        configurationFingerprint: window.configurationFingerprint)
                }
                try await archive.commitAnalysisBatch(ticket: ticket, windows: windows, analyzedCoverage: result.analyzedCoverage,
                    noSpeechCoverage: result.noSpeechCoverage,
                    checkpoint: result.checkpoint.map { .init(sessionID: $0.sessionID, epochID: $0.epochID, sourceFrame: $0.sourceFrame,
                        configurationFingerprint: $0.configurationFingerprint) }, waitingForMoreAudio: result.waitingForMoreAudio)
            } catch { try await archive.cancelEpochAnalysis(ticket: ticket); throw error }
        }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let frozen = try #require(await coordinator.freezeBatch())
        let completions = OSAllocatedUnfairLock(initialState: [TranscriptionBatchEndReason]())
        _ = try await coordinator.startBatch(id: frozen.id, origin: .foreground) { value in
            completions.withLock { $0.append(value.reason) }
        }
        #expect(await Task.detached { waitForPipelineEntry(entered) }.value)
        let handoff = try #require(await coordinator.prepareUserContinuationBatch())
        #expect(handoff.id == frozen.id && handoff.windowIDs == frozen.windowIDs && handoff.state == .ready)
        #expect(completions.withLock { $0 } == [.interrupted])
        #expect(!returned.withLock { $0 }, "Handoff must persist the stop without waiting for native ASR.")
        _ = try await coordinator.startBatch(id: handoff.id, origin: .continuedProcessing) { value in
            completions.withLock { $0.append(value.reason) }
        }
        await coordinator.suspendForSystem()
        release.signal()
        _ = await coordinator.runUntilIdle()
        let completed = try await archive.transcriptionBatch(id: handoff.id)
        #expect(completed.state == .completed)
        #expect(abs(completed.completedDuration - completed.totalDuration) < 0.01)
        #expect(completions.withLock { $0 } == [.interrupted, .completed])
        #expect(!timedOut.withLock { $0 })
    }

    @Test func newAudioTakesTheNextRecognitionSlotAfterAnInFlightHistoricalWindow() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("arrival-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"), directory: root.appendingPathComponent("capture"))
        _ = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: Date().addingTimeInterval(-172_800))
        _ = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: Date().addingTimeInterval(-259_200))
        let entered = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        let first = OSAllocatedUnfairLock(initialState: true)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(), onEvent: { event in
            guard case .nativeDecodeStarted = event, first.withLock({ value in defer { value = false }; return value }) else { return }
            entered.signal()
            if released.wait(timeout: .now() + 15) != .success { timedOut.withLock { $0 = true } }
        })
        defer { released.signal() }
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let sessions = OSAllocatedUnfairLock(initialState: [UUID]())
        await coordinator.observeClaims { kind, id in if kind == .transcription { sessions.withLock { $0.append(id) } } }
        let run = Task { await coordinator.runUntilIdle() }
        let started = await Task.detached { waitForPipelineEntry(entered) }.value
        #expect(started)
        let current = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: Date().addingTimeInterval(-120))
        await coordinator.requestWork()
        released.signal()
        let report = await run.value
        #expect(!timedOut.withLock { $0 })
        #expect(report.snapshot.phase == .idle)
        #expect(sessions.withLock { $0.dropFirst().first } == current.sessionID)
    }

    @Test func currentRecordingReachesRecognitionBeforeHistoricalRecordings() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("priority-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"), directory: root.appendingPathComponent("capture"))
        let old = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: Date().addingTimeInterval(-172_800))
        let current = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: Date().addingTimeInterval(-120))
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration())
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let sessions = OSAllocatedUnfairLock(initialState: [UUID]())
        await coordinator.observeClaims { kind, id in if kind == .transcription { sessions.withLock { $0.append(id) } } }
        let report = await coordinator.runUntilIdle()
        #expect(report.snapshot.phase == .idle)
        #expect(sessions.withLock { $0.first } == current.sessionID)
        #expect(sessions.withLock { $0.contains(old.sessionID) })
        #expect(!report.snapshot.nativeInFlight)
    }

    @Test func uninterruptedEpochProcessesTodayBeforeYesterdayWithoutAnEndEvent() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("midnight-\(UUID())")
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"), directory: root.appendingPathComponent("capture"))
        let day = TimelineDay(Date(), calendar: .current).date(calendar: TimelineDay.calendar)
        let recording = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive,
            wallClockAnchor: day.addingTimeInterval(-28_800 - 60), closeEpoch: false, sealedAt: Date().addingTimeInterval(-3_600))
        let decoded = OSAllocatedUnfairLock(initialState: [String]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(), onEvent: { event in
            if case .nativeDecodeStarted(let id) = event { decoded.withLock { $0.append(id) } }
        })
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let report = await coordinator.runUntilIdle()
        #expect(report.snapshot.phase == .idle)
        let firstID = try #require(decoded.withLock { $0.first })
        let firstCore = try await archive.processingTestCore(windowID: firstID)
        #expect(firstCore.start >= 60 * 16_000)
        let coverage = try await archive.recordingCoverage(sessionID: recording.sessionID, configurationFingerprint: engine.configurationFingerprint)
        #expect(coverage.epochs.first?.closedAtFrame == nil)
        #expect(coverage.epochs.allSatisfy { $0.pending.isEmpty })
        #expect(coverage.processedDuration == coverage.receivedDuration)
    }

    @Test(arguments: Mode.allCases)
    func boundedAnalysisPipelinePreservesCancellationAndRecovery(_ mode: Mode) async throws {
        try await runBoundedPipeline(mode, backend: .sherpa)
    }

    @Test(.enabled(if: MLComputeDevice.allComputeDevices.contains { if case .neuralEngine = $0 { return true }; return false }),
          arguments: Mode.allCases)
    func coreMLPipelinePreservesCancellationAndRecovery(_ mode: Mode) async throws {
        try await runBoundedPipeline(mode, backend: .sherpaCoreML)
    }

    private func runBoundedPipeline(_ mode: Mode, backend: SpeechRecognitionBackend) async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"]))
        let root = output.appendingPathComponent("pipeline-\(UUID())")
        let interrupt = mode == .pause || mode == .backgroundExpiry
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"),
            directory: root.appendingPathComponent("capture"))
        let recordedAt = Date().addingTimeInterval(-120)
        let first = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: recordedAt)
        let incoming = OSAllocatedUnfairLock<TranscriptionIntegrationScenario.IngestedAudio?>(initialState: nil)
        let gate = RecognitionGate()
        let decodeEntered = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        // Core ML's first ANE specialization happens before nativeDecodeStarted.
        let modelEntryTimeout: TimeInterval = backend == .sherpaCoreML ? 180 : 10
        let state = OSAllocatedUnfairLock(initialState: (claimedWindow: false, prefetched: false, decodes: 0, timedOut: false, inDecode: false, preparesDuringDecode: 0))
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(), recognitionBackend: backend, onDiagnostics: { value in
            if value.operation == .prepare { state.withLock { if $0.inDecode { $0.preparesDuringDecode += 1 } } }
            if !interrupt, value.operation == .prepare, state.withLock({ $0.prefetched }) { released.signal() }
        }, onEvent: { event in
            if case .analysisPageReady(let count) = event {
                let firstPage = state.withLock { value in
                    guard count > 0, !value.prefetched, mode != .serial else { return false }
                    value.prefetched = true
                    return true
                }
                if firstPage, decodeEntered.wait(timeout: .now() + modelEntryTimeout) != .success { state.withLock { $0.timedOut = true } }
                return
            }
            if case .nativeDecodeReturned = event { state.withLock { $0.inDecode = false }; return }
            guard case .nativeDecodeStarted = event else { return }
            let firstDecode = state.withLock { $0.inDecode = true; $0.decodes += 1; return $0.decodes == 1 }
            guard firstDecode, mode != .serial else { return }
            decodeEntered.signal()
            Task { await gate.open() }
            if released.wait(timeout: .now() + 10) != .success { state.withLock { $0.timedOut = true } }
        })
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: mode == .backgroundExpiry)
        await coordinator.setAnalysisPrefetchEnabled(mode != .serial)
        await coordinator.observeClaims { [weak coordinator] kind, _ in
            guard let coordinator else { return }
            if kind == .transcription {
                let firstWindow = state.withLock { value in
                    defer { value.claimedWindow = true }
                    return !value.claimedWindow
                }
                if firstWindow {
                    do {
                        // New input arrives after selection, so same-priority prefetch has useful work.
                        let received = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive, wallClockAnchor: recordedAt)
                        incoming.withLock { $0 = received }
                    } catch { Issue.record(error) }
                    if interrupt {
                        Task {
                            await gate.wait()
                            do {
                                if mode == .backgroundExpiry {
                                    let snapshot = await coordinator.snapshot()
                                    let execution = try #require(snapshot.execution)
                                    try await coordinator.stop(execution: execution, reason: .backgroundExpired)
                                } else { try await coordinator.pauseByUser() }
                            } catch { Issue.record(error) }
                            released.signal()
                        }
                    }
                }
                return
            }
        }
        if mode == .backgroundExpiry { _ = try await coordinator.startBackgroundAutomatic { _ in } }
        var report = await coordinator.runUntilIdle()
        #expect(state.withLock { $0.prefetched } == (mode != .serial))
        #expect(!state.withLock { $0.timedOut })
        #expect(!report.snapshot.nativeInFlight)
        if mode == .overlap { #expect(state.withLock { $0.preparesDuringDecode } > 0) }
        if mode == .serial { #expect(state.withLock { $0.preparesDuringDecode } == 0) }
        if interrupt {
            #expect(report.snapshot.phase == (mode == .backgroundExpiry ? .systemSuspended : .paused))
            do {
                let beforeResume = try await archive.readTranscript(sessionID: first.sessionID)
                #expect(beforeResume.spans.isEmpty)
            } catch let error as ArchiveError {
                #expect(error == .missingTranscript(first.sessionID))
            }
            await coordinator.setAnalysisPrefetchEnabled(false)
            if mode == .backgroundExpiry { await coordinator.resumeAfterSystemSuspension() }
            else { try await coordinator.resumeByUser() }
            report = await coordinator.runUntilIdle()
        }
        #expect(report.snapshot.phase == .idle)
        #expect(report.snapshot.failureCode == nil)
        let second = try #require(incoming.withLock { $0 })
        for received in [first, second] {
            let document = try await archive.readTranscript(sessionID: received.sessionID)
            #expect(!document.spans.isEmpty)
            _ = try await archive.deleteSession(id: received.sessionID)
            #expect(received.audioURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
    }
}

private extension ArchiveStore {
    func processingTestCore(windowID: String) throws -> FrameRange {
        let row = try #require(database.rows("SELECT descriptor FROM analysis_windows WHERE id=?", [.text(windowID)]).first)
        return try WireJSON.decode(ArchiveAnalysisWindow.self, from: row.requireData(0)).coreFrames
    }
}

private actor RecognitionGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private func waitForPipelineEntry(_ entered: DispatchSemaphore) -> Bool {
    entered.wait(timeout: .now() + 15) == .success
}
