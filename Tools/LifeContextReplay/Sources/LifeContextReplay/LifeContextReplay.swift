#if !DEBUG
#error("LifeContextReplay is a Debug-only integration diagnostic. Use swift run -c debug.")
#endif
import Darwin
import Foundation
import PiDurableKit
import MoMoArchive
import MoMoContracts
@testable import MoMoAgent

@main struct LifeContextReplay {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            print("Usage: LifeContextReplay MODEL_DIRECTORY OFFICIAL_ZH_WAV NEW_OUTPUT_DIRECTORY")
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else {
            print("NOT_RUN: output directory already exists; choose a new directory.")
            exit(64)
        }
        var evidence = LifeContextEvidence()
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let environment = ProcessInfo.processInfo.environment
            guard let key = environment["MOMO_E2E_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                evidence.failureCode = "missing_explicit_test_api_key"
                try evidence.save(to: output)
                print("NOT_RUN: MOMO_E2E_API_KEY is missing. No ASR or remote model request was started.")
                exit(64)
            }
            let address = environment["MOMO_E2E_BASE_URL"] ?? "https://dashscope.aliyuncs.com/compatible-mode/v1"
            guard let baseURL = URL(string: address) else { throw LifeContextFailure.invalidProvider }
            let configuration = try AgentProviderConfiguration(baseURL: baseURL,
                modelID: environment["MOMO_E2E_MODEL"] ?? "qwen-plus", compatibility: .bailianBeijing)
            evidence.provider = "bailianBeijing"
            evidence.model = configuration.modelID
            evidence.status = "running"
            evidence.stage = "local_transcription"
            try evidence.save(to: output)
            let audioChunks = try PhoneTranscriptionFixture.makeCrossChunk(
                officialWAV: URL(fileURLWithPath: arguments[2]), directory: output.appendingPathComponent("capture"))
            let phone = output.appendingPathComponent("phone")
            let transcription = try await TranscriptionIntegrationScenario.run(rootURL: phone,
                modelDirectory: URL(fileURLWithPath: arguments[1], isDirectory: true), audioChunks: audioChunks,
                expectedFragments: PhoneTranscriptionFixture.expectedFragments)
            guard transcription.chunkCount == 2, transcription.sourceRangeCount >= 2,
                  transcription.report.transcribedWindows > 0 else { throw LifeContextFailure.crossFileASRNotExercised }
            let archive = try ArchiveStore(rootURL: phone, receiverDeviceID: UUID())
            let document = try await archive.readTranscript(sessionID: transcription.sessionID)
            let sources = document.spans.map { document.source(for: $0) }
            let crossFileSources = document.spans.filter { Set($0.sourceRanges.map(\.chunkID)).count >= 2 }.map { document.source(for: $0) }
            guard !sources.isEmpty, !crossFileSources.isEmpty else { throw LifeContextFailure.crossFileASRNotExercised }
            evidence.recordingSessionID = document.sessionID
            evidence.transcriptSHA256 = ContentHash.sha256(try WireJSON.encode(document))
            evidence.transcribedWindows = transcription.report.transcribedWindows
            // This replay imports a fixed-date audio fixture. Freeze the request relative to that
            // original capture date rather than silently rewriting it or letting it age out of context.
            let snapshot = try await archive.transcriptSnapshot(sessionID: document.sessionID)
            guard let latestRecordedAt = snapshot.locations.values.map(\.recordedAt).max() else {
                throw LifeContextFailure.crossFileASRNotExercised
            }
            let clock = AgentContextClock(now: latestRecordedAt.addingTimeInterval(60), timezone: "Asia/Shanghai")
            let context = try await ContextBuilder(archive: archive).build(clock: clock)
            guard !context.passages.isEmpty,
                  context.passages.allSatisfy({ $0.source.sessionID == document.sessionID && $0.contextRole == "automatic_recent" }),
                  context.passages.contains(where: { crossFileSources.contains($0.source) }) else {
                throw LifeContextFailure.automaticContextMissing
            }
            evidence.requestClock = clock
            evidence.contextBeforeSendSources = context.passages.map(\.source)
            evidence.stage = "real_model_request"
            try evidence.save(to: output)

            // Credentials live only in this test process; production Keychain entries are untouched.
            let network = URLSessionConfiguration.ephemeral
            network.timeoutIntervalForRequest = 30
            network.timeoutIntervalForResource = 120
            network.waitsForConnectivity = false
            network.httpCookieStorage = nil
            network.urlCache = nil
            let runtime = Runtime(configuration: .init(urlSessionConfiguration: network, log: { _, _ in }))
            let models = Models(credentials: .inMemory, builtinProviders: false, runtime: runtime)
            try await models.register(ProviderAccess.customProvider(configuration, apiKey: key))
            let access = ProviderAccess(models: models, configuration: configuration)
            let host = try PiAgentHost(storageURL: output.appendingPathComponent("agent"), archive: archive,
                provider: access, contextClock: { clock })
            do {
                let agentSession = try await host.createSession()
                let requestID = UUID()
                evidence.agentSessionID = agentSession
                evidence.requestID = requestID
                evidence.registeredTools = ArchiveTools.names
                try evidence.save(to: output)
                evidence.remoteRequestStarted = true
                try evidence.save(to: output)
                let answer = try await host.submit(text: "刚才说了什么时间，具体是指什么？简短回答并附来源，没听清的别猜。",
                                                   sessionID: agentSession, requestID: requestID)
                guard !answer.text.isEmpty, !answer.sources.isEmpty,
                      answer.sources.allSatisfy(sources.contains) else { throw LifeContextFailure.answerSourceMismatch }
                evidence.answerCitations = try SourceAudioValidation.citations(in: answer.text, allowed: sources)
                guard evidence.answerCitations.contains(where: crossFileSources.contains) else {
                    throw LifeContextFailure.answerSourceMismatch
                }
                try await archive.validateSources(evidence.answerCitations)
                evidence.stage = "source_audio_validation"
                try evidence.save(to: output)
                for source in evidence.answerCitations {
                    evidence.audioSources.append(try await SourceAudioValidation.verify(source: source, archive: archive))
                }
                guard evidence.audioSources.contains(where: { Set($0.parts.map(\.chunkID)).count >= 2 }) else {
                    throw LifeContextFailure.crossFilePlaybackNotExercised
                }
                evidence.answerSHA256 = ContentHash.sha256(Data(answer.text.utf8))
                try await host.close()
            } catch {
                let original = error
                try await host.close()
                throw original
            }
            evidence.status = "passed"
            evidence.stage = "complete"
            try evidence.save(to: output)
            print("PASS: real cross-file VAD/ASR → Pi model API → sourced answer → decoded original audio ranges.")
            print("Evidence: \(output.path)")
        } catch {
            evidence.status = "failed"
            evidence.failureCode = (error as? LifeContextFailure)?.rawValue ?? String(reflecting: type(of: error))
            do { try evidence.save(to: output) }
            catch { print("FAILED: evidence_write_failed") }
            // Provider errors may contain server payloads; neither those payloads nor credentials are logged.
            print("FAILED at \(evidence.stage): \(evidence.failureCode ?? "unspecified")")
            exit(1)
        }
    }
}

enum LifeContextFailure: String, Error {
    case invalidProvider, crossFileASRNotExercised, answerSourceMismatch
    case crossFilePlaybackNotExercised, sourceAudioMismatch
    case automaticContextMissing
}

struct LifeContextEvidence: Codable {
    var status = "not-run"
    var stage = "credentials"
    var failureCode: String?
    var provider: String?
    var model: String?
    var recordingSessionID: UUID?
    var transcriptSHA256: String?
    var transcribedWindows: Int?
    var requestClock: AgentContextClock?
    // Production ContextBuilder evidence, not an intercepted HTTP payload.
    var contextBeforeSendSources: [SourceReference] = []
    var agentSessionID: UUID?
    var requestID: UUID?
    var registeredTools: [String] = []
    var remoteRequestStarted = false
    var answerCitations: [SourceReference] = []
    var answerSHA256: String?
    var audioSources: [VerifiedAudioSource] = []
    func save(to directory: URL) throws {
        try WireJSON.encode(self).write(to: directory.appendingPathComponent("evidence.json"), options: .atomic)
    }
}
