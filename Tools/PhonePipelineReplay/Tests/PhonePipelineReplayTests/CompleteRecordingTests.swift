import AVFoundation
import Foundation
import os
import Testing
import MoMoArchive
import MoMoContracts
import MoMoSpeech
@testable import PhonePipelineReplay

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct CompleteRecordingTests {
    @Test @MainActor func laterAudioContinuesAnAlreadyProcessedOpenRecording() async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("incremental-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: model.appendingPathComponent("test_wavs/zh.wav"),
            directory: root.appendingPathComponent("capture"))
        let archive = try ArchiveStore(rootURL: root.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            continuousArchive: true, onDiagnostics: { value in diagnostics.withLock { $0.append(value) } }, onEvent: { _ in })
        try engine.setVoiceActivityThreshold(0.25)
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let session = UUID(), epoch = UUID(), source = UUID(), anchor = Date()
        var position: Int64 = 0
        for (index, file) in files.enumerated() {
            let count = try AVAudioFile(forReading: file).length
            let manifest = try ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: source, sourceBuild: "test",
                sequence: Int64(index), frames: FrameRange(start: position, count: count), timebaseHz: 16_000,
                wallClockAnchor: anchor, timezoneOffset: 0, codec: .pcmInt16, sampleRate: 16_000, channels: 1,
                decodedFrameCount: count, byteCount: Int64(Data(contentsOf: file).count), audioSHA256: ContentHash.sha256(fileAt: file),
                sourceKind: .fixture)
            _ = try await archive.commitReceivedChunk(archive.inbox.preserve(fileURL: file, envelope: ManifestEnvelope(manifest: manifest)))
            let report = await coordinator.runUntilIdle()
            #expect(report.snapshot.failureCode == nil)
            let coverage = try await archive.recordingCoverage(sessionID: session, configurationFingerprint: engine.configurationFingerprint)
            #expect((coverage.processedDuration ?? 0) <= coverage.receivedDuration)
            position += count
        }
        try await archive.markEpochClosed(epochID: epoch, endFrame: position)
        #expect(await coordinator.runUntilIdle().snapshot.phase == .idle)
        #expect(diagnostics.withLock { $0.filter { $0.operation == .prepare }.count } <= 6,
            "Two receipts and an end event must not generate hundreds of moving time-boundary tickets.")
        let text = try await archive.readTranscript(sessionID: session).spans.map(\.text).joined().filter { $0.isLetter || $0.isNumber }
        #expect(text == "开放时间早上9点至下午5点", "Incremental transcript: \(text)")
    }

    @Test(arguments: [false, true]) @MainActor
    func ongoingRecordingPublishesBeforeEndAndRetainsOnlyUndecidedTail(restart: Bool) async throws {
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("complete-recording-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
        let source = model.appendingPathComponent("test_wavs/zh.wav")
        let recording = try await TranscriptionIntegrationScenario.ingest(Array(repeating: source, count: 24),
            archive: archive, wallClockAnchor: Date(), closeEpoch: false)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        var engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(language: "zh"),
            continuousArchive: true, onEvent: { event in
                guard restart, case .nativeDecodeStarted = event else { return }
                let current = count.withLock { $0 += 1; return $0 }
                if current == 3 {
                    entered.signal()
                    if release.wait(timeout: .now() + 15) != .success { timedOut.withLock { $0 = true } }
                }
            })
        defer { release.signal() }
        try engine.setVoiceActivityThreshold(0.25)
        var coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let initial = coordinator
        let running = Task { await initial.runUntilIdle() }
        if restart {
            #expect(await Task.detached { waitForRecordingDecode(entered) }.value)
            try await coordinator.pauseByUser()
            release.signal()
            #expect(await running.value.snapshot.phase == .paused)
            engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(language: "zh"),
                continuousArchive: true)
            try engine.setVoiceActivityThreshold(0.25)
            coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
            #expect(await coordinator.snapshot().userPaused)
            try await coordinator.resumeByUser()
        }
        let report = restart ? await coordinator.runUntilIdle() : await running.value
        #expect(!timedOut.withLock { $0 })
        #expect(report.snapshot.failureCode == nil)
        #expect(report.snapshot.phase == .waitingForContext)
        let coverage = try await archive.recordingCoverage(sessionID: recording.sessionID,
            configurationFingerprint: engine.configurationFingerprint)
        #expect(coverage.receivedDuration > 120)
        #expect(coverage.receivedDuration - (coverage.processedDuration ?? 0) < 20)
        #expect(coverage.epochs.allSatisfy { $0.closedAtFrame == nil })
        let partial = try await archive.readTranscript(sessionID: recording.sessionID)
        #expect(!partial.spans.isEmpty)
        _ = await coordinator.runUntilIdle()
        #expect(try await archive.readTranscript(sessionID: recording.sessionID).version == partial.version,
            "Waiting for the next receipt must not repeatedly recognize the same tail.")
        for epoch in coverage.epochs {
            try await archive.markEpochClosed(epochID: epoch.id, endFrame: #require(epoch.received.last).end)
        }
        #expect(await coordinator.runUntilIdle().snapshot.phase == .idle)
        let completed = try await archive.recordingCoverage(sessionID: recording.sessionID,
            configurationFingerprint: engine.configurationFingerprint)
        #expect(completed.processedDuration == completed.receivedDuration)
        let document = try await archive.readTranscript(sessionID: recording.sessionID)
        let text = document.spans.map(\.text).joined().filter { $0.isLetter || $0.isNumber }
        #expect(text == String(repeating: "开放时间早上9点至下午5点", count: 24), "Continuous transcript: \(text)")
        let before = document.version
        _ = await coordinator.runUntilIdle()
        #expect(try await archive.readTranscript(sessionID: recording.sessionID).version == before)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOMO_RECALL_SAMPLE_MANIFEST"] != nil))
    @MainActor func fixedRecordingSamplesReportWorkWithoutChangingTheDeviceLibrary() async throws {
        struct Sample: Decodable { let id: String; let path: String; let minimumCharacters: Int?; let maximumCharacters: Int? }
        struct Result: Encodable {
            let id: String; let characters: Int; let seconds: Double; let processingSeconds: Double
            let selectedSeconds: Double; let skippedSeconds: Double; let recognitionInputSeconds: Double
            let nativeDecodeSeconds: Double; let vadThreshold: Float; let configurationFingerprint: String
        }
        let manifest = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_RECALL_SAMPLE_MANIFEST"]))
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: manifest))
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            continuousArchive: true, onDiagnostics: { event in diagnostics.withLock { $0.append(event) } }, onEvent: { _ in })
        try engine.setVoiceActivityThreshold(0.25)
        var results: [Result] = []
        for sample in samples {
            diagnostics.withLock { $0.removeAll(keepingCapacity: true) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-copy-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = try ArchiveStore(rootURL: root, receiverDeviceID: UUID())
            let input = try await TranscriptionIntegrationScenario.ingest([URL(fileURLWithPath: sample.path)],
                archive: archive, wallClockAnchor: Date(), closeEpoch: false)
            let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
            let start = Date()
            let report = await coordinator.runUntilIdle()
            #expect(report.snapshot.failureCode == nil, "Sample \(sample.id)")
            let coverage = try await archive.recordingCoverage(sessionID: input.sessionID, configurationFingerprint: engine.configurationFingerprint)
            #expect(coverage.processedDuration == coverage.receivedDuration)
            let characters: Int
            do {
                let document = try await archive.readTranscript(sessionID: input.sessionID)
                characters = document.spans.map(\.text).joined().filter { $0.isLetter || $0.isNumber }.count
            } catch ArchiveError.missingTranscript {
                // A fully skipped non-speech recording has no recognition document.
                characters = 0
            }
            if let minimum = sample.minimumCharacters { #expect(characters >= minimum, "Sample \(sample.id)") }
            if let maximum = sample.maximumCharacters { #expect(characters <= maximum, "Sample \(sample.id)") }
            let counters = diagnostics.withLock { $0 }
            results.append(Result(id: sample.id, characters: characters, seconds: coverage.receivedDuration,
                processingSeconds: Date().timeIntervalSince(start),
                selectedSeconds: Double(counters.reduce(0) { $0 + ($1.selectedArchiveModelFrames ?? 0) }) / 16_000,
                skippedSeconds: Double(counters.reduce(0) { $0 + ($1.skippedArchiveModelFrames ?? 0) }) / 16_000,
                recognitionInputSeconds: Double(counters.reduce(0) { $0 + ($1.recognitionInputModelFrames ?? 0) }) / 16_000,
                nativeDecodeSeconds: counters.reduce(0) { $0 + $1.nativeDecodeSeconds },
                vadThreshold: engine.voiceActivityThreshold, configurationFingerprint: engine.configurationFingerprint))
        }
        try JSONEncoder().encode(results).write(to: manifest.deletingPathExtension().appendingPathExtension("results.json"), options: .atomic)
    }
}

private func waitForRecordingDecode(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 15) == .success
}
