import Foundation
import os
import MoMoArchive
import MoMoContracts
import MoMoSpeech

enum SparseHourBenchmark {
    static func run(model: URL, fixture: URL, output: URL) async throws {
        let chunks = try PhoneTranscriptionFixture.makeSparseHour(officialWAV: fixture,
            directory: output.appendingPathComponent("capture"))
        let archive = try ArchiveStore(rootURL: output.appendingPathComponent("phone"), receiverDeviceID: UUID())
        let importStarted = DispatchTime.now().uptimeNanoseconds
        let received = try await TranscriptionIntegrationScenario.ingest(chunks, archive: archive,
            closeEpoch: false, sealedAt: Date().addingTimeInterval(-7_200))
        let importSeconds = elapsed(since: importStarted)
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            continuousArchive: true,
            onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
        let coordinator = try TranscriptionCoordinator(archive: archive, speech: engine, startSuspended: false)
        let processingStarted = DispatchTime.now().uptimeNanoseconds
        let report = await coordinator.runUntilIdle()
        let processingSeconds = elapsed(since: processingStarted)
        let coverage = try await archive.recordingCoverage(sessionID: received.sessionID,
            configurationFingerprint: engine.configurationFingerprint)
        let document = try await archive.readTranscript(sessionID: received.sessionID)
        let expected = PhoneTranscriptionFixture.expectedFragments[0]
        guard report.snapshot.phase == .idle, report.transcribedWindows >= 60, document.spans.count == 60,
              abs(coverage.receivedDuration - 3_600) < 0.01,
              coverage.epochs.allSatisfy({ $0.closedAtFrame == nil }),
              document.spans.enumerated().allSatisfy({ index, span in
                  span.frames.start / (60 * 16_000) == Int64(index)
                      && span.text.filter { !$0.isWhitespace }.trimmingCharacters(in: CharacterSet(charactersIn: "。.")) == expected
              }),
              let processed = coverage.processedDuration, abs(processed - 3_600) < 0.01 else {
            throw TranscriptionIntegrationFailure.lifecycleInvariant("sparse_hour_did_not_finish_received_audio")
        }
        let diagnostics = observations.withLock { $0 }
        let result = SparseHourEvidence(environment: "macOS native production coordinator; synthetic sparse speech; no explicit recording end",
            os: ProcessInfo.processInfo.operatingSystemVersionString, cpuThreads: ProcessInfo.processInfo.processorCount,
            configurationFingerprint: engine.configurationFingerprint,
            receivedSeconds: coverage.receivedDuration, processedSeconds: processed,
            importSeconds: importSeconds, processingSeconds: processingSeconds,
            realTimeFactor: processingSeconds / coverage.receivedDuration,
            fiveMinuteTargetMet: processingSeconds <= 300, transcribedWindows: report.transcribedWindows,
            asrCoreSeconds: Double(diagnostics.reduce(Int64(0)) { $0 + $1.coreModelFrames }) / 16_000,
            recognitionInputSeconds: Double(diagnostics.reduce(Int64(0)) { $0 + ($1.recognitionInputModelFrames ?? 0) }) / 16_000,
            skippedSeconds: Double(diagnostics.reduce(Int64(0)) { $0 + ($1.skippedArchiveModelFrames ?? 0) }) / 16_000,
            vadInputSeconds: Double(diagnostics.reduce(Int64(0)) { $0 + $1.vadModelFrames }) / 16_000,
            nativeASRSeconds: diagnostics.reduce(0) { $0 + $1.nativeDecodeSeconds },
            resampledSeconds: Double(diagnostics.reduce(Int64(0)) { $0 + $1.convertedModelFrames }) / 16_000,
            cachedPCMSeconds: Double(diagnostics.reduce(Int64(0)) { $0 + $1.preparedAudioModelFrames }) / 16_000)
        try WireJSON.encode(result).write(to: output.appendingPathComponent("throughput.json"), options: .atomic)
        try WireJSON.encode(diagnostics).write(to: output.appendingPathComponent("speech-diagnostics.json"), options: .atomic)
        print("PASS: 3600 seconds received and processed without a recording-end event.")
        print("Processing seconds: \(processingSeconds); RTF: \(result.realTimeFactor); five-minute target: \(result.fiveMinuteTargetMet)")
        print("This Mac workload does not measure physical iPhone speed, natural speech accuracy, radio transfer, or iOS scheduling.")
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}

private struct SparseHourEvidence: Codable {
    let environment: String
    let os: String
    let cpuThreads: Int
    let configurationFingerprint: String
    let receivedSeconds: Double
    let processedSeconds: Double
    let importSeconds: Double
    let processingSeconds: Double
    let realTimeFactor: Double
    let fiveMinuteTargetMet: Bool
    let transcribedWindows: Int
    let asrCoreSeconds: Double
    let recognitionInputSeconds: Double
    let skippedSeconds: Double
    let vadInputSeconds: Double
    let nativeASRSeconds: Double
    let resampledSeconds: Double
    let cachedPCMSeconds: Double
}
