@preconcurrency import AVFoundation
import Foundation
import MoMoContracts
import MoMoSpeech

@main struct SpeechQuality {
    static func main() async throws {
        let arguments = CommandLine.arguments
#if MOMO_SPEECH_BENCHMARK
        if arguments.dropFirst().first == "--backend-benchmark" {
            try await SpeechBackendBenchmark.run(arguments: Array(arguments.dropFirst(2)))
            return
        }
#endif
        if arguments.dropFirst().first == "--diagnostics" {
            try await SpeechDiagnosticsRun.run(arguments: Array(arguments.dropFirst(2)))
            return
        }
        guard arguments.count == 5 else {
            throw QualityFailure.invalid("Usage: SpeechQuality MODEL_DIRECTORY CORPUS_DIRECTORY NEW_OUTPUT_DIRECTORY SOURCE_VERSION")
        }
        let modelURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let corpusURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let outputURL = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let manifestURL = corpusURL.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.status == "prepared", manifest.sampleRate == 16_000,
              manifest.items.count == Set(manifest.items.map(\.id)).count,
              manifest.items.count == Set(manifest.items.map(\.sentenceID)).count,
              manifest.items.reduce(0, { $0 + $1.frames }) == 57_600_000,
              !FileManager.default.fileExists(atPath: outputURL.path),
              !arguments[4].isEmpty else { throw QualityFailure.invalid("Invalid corpus or output directory") }
        guard try ContentHash.sha256(fileAt: corpusURL.appendingPathComponent("selection.json")) == manifest.selectionSHA256 else {
            throw QualityFailure.invalid("Selection checksum mismatch")
        }
        let configuration = try SpeechConfiguration()
        let bundle = try SpeechModelBundle.load(from: modelURL)
        let engine = try SpeechEngine(bundle: bundle, configuration: configuration)
        let metadata = RunMetadata(
            schemaVersion: 1, toolRuleVersion: "filewise-closed-epoch-v1", sourceVersion: arguments[4],
            corpusSHA256: try ContentHash.sha256(fileAt: manifestURL),
            configurationFingerprint: engine.configurationFingerprint, configuration: configuration,
            modelManifest: bundle.manifest, sampleCount: manifest.items.count,
            sourceFrames: manifest.items.reduce(0, { $0 + $1.frames }),
            platform: ProcessInfo.processInfo.operatingSystemVersionString,
            scope: "Mac production SpeechEngine; each source file is a separate closed epoch; no Watch or background scheduling",
            annotationStatus: manifest.annotationStatus)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try WireJSON.encode(metadata).write(to: outputURL.appendingPathComponent("run.json"), options: .atomic)
        let resultsURL = outputURL.appendingPathComponent("utterances.jsonl")
        try Data().write(to: resultsURL, options: .withoutOverwriting)
        var failures = 0
        let runStart = ProcessInfo.processInfo.systemUptime
        for (index, item) in manifest.items.enumerated() {
            let start = ProcessInfo.processInfo.systemUptime
            var windows: [WindowOutput] = []
            var analyzed: [FrameRange] = []
            var noSpeech: [FrameRange] = []
            var failure: String?
            do {
                let input = try makeInput(item: item, corpusURL: corpusURL)
                var checkpoint: SpeechCheckpoint?
                var position: Int64 = 0
                var windowIDs = Set<String>()
                while position < item.frames {
                    let batch = try await engine.prepare(inputs: [input], resume: checkpoint, epochClosed: true)
                    guard let next = batch.checkpoint, next.sourceFrame > position,
                          next.sourceFrame <= item.frames, !batch.waitingForMoreAudio else {
                        throw QualityFailure.invalid("Analysis did not advance through the closed epoch")
                    }
                    analyzed.append(contentsOf: batch.analyzedCoverage)
                    noSpeech.append(contentsOf: batch.noSpeechCoverage)
                    for window in batch.windows {
                        guard windowIDs.insert(window.id).inserted else {
                            throw QualityFailure.invalid("Duplicate speech window")
                        }
                        let decodeStart = ProcessInfo.processInfo.systemUptime
                        let recognition = try await engine.transcribe(window: window, inputs: [input])
                        windows.append(WindowOutput(window: window, recognition: recognition,
                                                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - decodeStart))
                    }
                    position = next.sourceFrame
                    checkpoint = next
                }
            } catch {
                failures += 1
                failure = String(describing: error)
            }
            let result = UtteranceOutput(id: item.id, sentenceID: item.sentenceID,
                audioSHA256: item.sha256, status: failure == nil ? "completed" : "error", error: failure,
                text: windows.map { $0.recognition.text }.joined(separator: " "), windows: windows,
                analyzedCoverage: analyzed, noSpeechCoverage: noSpeech,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - start)
            try append(result, to: resultsURL)
            print("\(index + 1)/\(manifest.items.count): \(item.id) \(result.status)")
        }
        try WireJSON.encode(RunCompletion(completedCount: manifest.items.count - failures, errorCount: failures,
                                         elapsedSeconds: ProcessInfo.processInfo.systemUptime - runStart))
            .write(to: outputURL.appendingPathComponent("completion.json"), options: .atomic)
        guard failures == 0 else { throw QualityFailure.invalid("\(failures) utterances failed; inspect utterances.jsonl") }
        print("Completed real VAD + ASR. Run score.py to calculate CER from independent references.")
    }

    // Return plain metadata only; AVAudioFile is released before a native decode can start.
    private static func makeInput(item: CorpusItem, corpusURL: URL) throws -> SpeechAudioInput {
        guard item.frames > 0, item.byteCount > 0, ContentHash.isValid(item.sha256),
              item.filename == URL(fileURLWithPath: item.filename).lastPathComponent else {
            throw QualityFailure.invalid("Invalid corpus audio identity")
        }
        let audioURL = corpusURL.appendingPathComponent("audio").appendingPathComponent(item.filename)
        guard try ContentHash.sha256(fileAt: audioURL) == item.sha256 else {
            throw QualityFailure.invalid("Audio checksum mismatch")
        }
        let file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let encoded = file.fileFormat.streamDescription.pointee
        guard file.length == item.frames, file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1, encoded.mFormatID == kAudioFormatLinearPCM else {
            throw QualityFailure.invalid("Decoded audio differs from the corpus manifest")
        }
        let codec: MoMoContracts.AudioCodec
        if encoded.mBitsPerChannel == 32, encoded.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            codec = .pcmFloat32
        } else if encoded.mBitsPerChannel == 16, encoded.mFormatFlags & kAudioFormatFlagIsFloat == 0 {
            codec = .pcmInt16
        } else { throw QualityFailure.invalid("Unsupported corpus WAV codec") }
        guard codec.rawValue == item.codec else { throw QualityFailure.invalid("WAV codec mismatch") }
        let manifest = try ChunkManifest(
            sessionID: stableID(item.id + ":session"), epochID: stableID(item.id + ":epoch"),
            chunkID: stableID(item.id + ":chunk"), sourceDeviceID: stableID("fleurs-zh"),
            sourceBuild: "speech-quality-v1", sequence: 0, frames: FrameRange(start: 0, count: item.frames),
            timebaseHz: 16_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0,
            codec: codec, sampleRate: 16_000, channels: 1, decodedFrameCount: item.frames,
            byteCount: item.byteCount, audioSHA256: item.sha256,
            sealedAt: Date(timeIntervalSince1970: Double(item.frames) / 16_000), sourceKind: .fixture)
        return SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: audioURL)
    }

    private static func stableID(_ value: String) throws -> UUID {
        let hex = Array(ContentHash.sha256(Data(value.utf8)).prefix(32))
        let text = [String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]),
                    String(hex[16..<20]), String(hex[20..<32])].joined(separator: "-")
        guard let id = UUID(uuidString: text) else { throw QualityFailure.invalid("Invalid fixture UUID") }
        return id
    }

    private static func append(_ result: UtteranceOutput, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: WireJSON.encode(result) + Data([10]))
        try handle.synchronize()
    }
}

private enum QualityFailure: Error { case invalid(String) }

private struct Corpus: Decodable {
    let schemaVersion: Int
    let status: String
    let sampleRate: Int
    let selectionSHA256: String
    let annotationStatus: String
    let items: [CorpusItem]
}

private struct CorpusItem: Decodable {
    let id: String
    let sentenceID: String
    let filename: String
    let frames: Int64
    let sha256: String
    let byteCount: Int64
    let codec: String
}

private struct RunMetadata: Encodable {
    let schemaVersion: Int
    let toolRuleVersion: String
    let sourceVersion: String
    let corpusSHA256: String
    let configurationFingerprint: String
    let configuration: SpeechConfiguration
    let modelManifest: SpeechModelManifest
    let sampleCount: Int
    let sourceFrames: Int64
    let platform: String
    let scope: String
    let annotationStatus: String
}

private struct WindowOutput: Encodable {
    let window: SpeechWindow
    let recognition: SpeechRecognition
    let elapsedSeconds: Double
}

private struct UtteranceOutput: Encodable {
    let id: String
    let sentenceID: String
    let audioSHA256: String
    let status: String
    let error: String?
    let text: String
    let windows: [WindowOutput]
    let analyzedCoverage: [FrameRange]
    let noSpeechCoverage: [FrameRange]
    let elapsedSeconds: Double
}

private struct RunCompletion: Encodable {
    let completedCount: Int
    let errorCount: Int
    let elapsedSeconds: Double
}
