import Foundation
import MoMoContracts

@main struct PhonePipelineReplay {
    static func main() async throws {
        let arguments = CommandLine.arguments
        let sparseHour = arguments.count == 5 && arguments[4] == "--sparse-hour"
        guard arguments.count == 4 || sparseHour else {
            throw ReplayFailure.usage("Usage: PhonePipelineReplay MODEL_DIRECTORY OFFICIAL_ZH_WAV NEW_OUTPUT_DIRECTORY [--sparse-hour]")
        }
        let model = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let fixture = URL(fileURLWithPath: arguments[2])
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ReplayFailure.outputAlreadyExists }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if sparseHour {
            try await SparseHourBenchmark.run(model: model, fixture: fixture, output: output)
            return
        }
        let chunks = try PhoneTranscriptionFixture.makeCrossChunk(officialWAV: fixture, directory: output.appendingPathComponent("capture"))
        let phone = output.appendingPathComponent("phone")
        let evidence = try await TranscriptionIntegrationScenario.run(rootURL: phone, modelDirectory: model,
            audioChunks: chunks, expectedFragments: PhoneTranscriptionFixture.expectedFragments)
        guard evidence.chunkCount == 2, evidence.sourceRangeCount >= 2 else { throw ReplayFailure.crossChunkNotExercised }
        try await TranscriptionIntegrationScenario.verifySavedContextLifecycle(rootURL: phone,
            sessionID: evidence.sessionID, stagingURL: output.appendingPathComponent("lifecycle-fixture"))
        let silent = try PhoneTranscriptionFixture.makeSilence(directory: output.appendingPathComponent("silence-capture"))
        try await TranscriptionIntegrationScenario.verifySilentRecording(rootURL: output.appendingPathComponent("silence-phone"),
            modelDirectory: model, audioURL: silent)
        try await TranscriptionIntegrationScenario.verifyDeleteDuringRecognition(rootURL: output.appendingPathComponent("delete-during-native"),
            modelDirectory: model, audioChunks: chunks)
        let result = ReplayEvidence(sessionID: evidence.sessionID, chunks: evidence.chunkCount,
            spans: evidence.spanCount, sourceRanges: evidence.sourceRangeCount,
            preparedBatches: evidence.report.preparedBatches, transcribedWindows: evidence.report.transcribedWindows,
            finalPhase: evidence.report.snapshot.phase.rawValue, lifecycle: "passed")
        try WireJSON.encode(result).write(to: output.appendingPathComponent("evidence.json"), options: .atomic)
        print("PASS: WAV → SQLite Archive → persistent pause/restart → Silero VAD + SenseVoice → cross-chunk transcript → JSON/Markdown")
        print("PASS: Chinese search → audio timeline → plan deduplication → deletion → stale context blocked → late transfer rejected")
        print("PASS: startup suspension → silent audio completes without ASR → native decode deletion retains leases until return")
        print("Evidence: \(output.path)")
    }

}

private enum ReplayFailure: Error {
    case usage(String), outputAlreadyExists, crossChunkNotExercised
}

private struct ReplayEvidence: Codable {
    let sessionID: UUID
    let chunks: Int
    let spans: Int
    let sourceRanges: Int
    let preparedBatches: Int
    let transcribedWindows: Int
    let finalPhase: String
    let lifecycle: String
}
