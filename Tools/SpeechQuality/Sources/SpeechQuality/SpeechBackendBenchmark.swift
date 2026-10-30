#if MOMO_SPEECH_BENCHMARK
@preconcurrency import AVFoundation
import Foundation
import os
import MoMoContracts
@testable import MoMoSpeech

/// Opt-in Release benchmark; never enters the app or the ordinary quality runner.
enum SpeechBackendBenchmark {
    static func run(arguments: [String]) async throws {
        guard arguments.count == 5 || arguments.count == 6 else { throw Failure.invalid("MODEL_DIRECTORY CORPUS_DIRECTORY NEW_OUTPUT_DIRECTORY SOURCE_VERSION MODE [SHARED_INPUT_ROOT]") }
        let sharedInputs = arguments.count == 6 ? URL(fileURLWithPath: arguments[5]) : nil
        guard sharedInputs == nil || ["pipeline-only", "pipeline-reverse", "pipeline-coreml"].contains(arguments[4]) else { throw Failure.invalid("Shared inputs require a regular pipeline mode") }
        let model = URL(fileURLWithPath: arguments[0]), corpus = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.invalid("Output must be new") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bundle = try SpeechModelBundle.load(from: model)
        try bundle.validate()
        let metadata: [String: String] = ["sourceVersion": arguments[3], "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "configuration": "Release -O with testing visibility", "scope": "Apple M4 software benchmark; no phone or power claim",
            "mode": arguments[4],
            "executableSHA256": try ContentHash.sha256(fileAt: URL(fileURLWithPath: CommandLine.arguments[0])),
            "modelManifestSHA256": try ContentHash.sha256(fileAt: model.appendingPathComponent("manifest.json"))]
        try save(metadata, output.appendingPathComponent("run.json"))
        if arguments[4] == "load-only" {
            try await Task.detached(priority: .utility) { try micro(bundle: bundle, voice: [], output: output, loadOnly: true) }.value
            return
        }
        guard ["full", "micro-only", "micro-coreml", "micro-sherpa", "pipeline-only", "pipeline-reverse", "pipeline-coreml", "pipeline-dense"].contains(arguments[4]) else { throw Failure.invalid("Unknown benchmark mode") }
        let (items, voice) = try corpusInputs(corpus: corpus, output: output)
        if arguments[4] == "micro-coreml" || arguments[4] == "micro-sherpa" {
            let backend: SpeechRecognitionBackend = arguments[4] == "micro-coreml" ? .sherpaCoreML : .sherpa
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue(label: "MoMoAgent.benchmark", qos: .utility).async {
                    do {
                        try autoreleasepool { try micro(bundle: bundle, voice: voice, output: output, loadOnly: false, isolated: backend) }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return
        }
        if arguments[4] == "full" || arguments[4] == "micro-only" {
            try await Task.detached(priority: .utility) { try micro(bundle: bundle, voice: voice, output: output, loadOnly: false) }.value
        }
        if arguments[4] == "pipeline-dense" {
            let fixture = bundle.directory.appendingPathComponent("test_wavs/zh.wav")
            guard try ContentHash.sha256(fileAt: fixture) == "b77f1794fe374a0ba1ee1dc458bfaf9349496cbbfc32780c50ba3c5a7ad8e373" else { throw Failure.invalid("Official fixture checksum mismatch") }
            let dense = try SpeechDiagnosticsRun.readVoice(fixture).map { Float($0) / 32_767 }
            try await pipeline(bundle: bundle, items: [], voice: dense, output: output, reverse: true, secondsList: [60])
        } else if arguments[4] != "micro-only" {
            try await pipeline(bundle: bundle, items: items, voice: voice, output: output, reverse: arguments[4] == "pipeline-reverse",
                sharedInputs: sharedInputs, coreMLOnly: arguments[4] == "pipeline-coreml")
        }
    }

    static func micro(bundle: SpeechModelBundle, voice: [Float], output: URL, loadOnly: Bool,
                      isolated: SpeechRecognitionBackend? = nil) throws {
        let config = try SpeechConfiguration(), attempt = SpeechAttempt()
        let cpuLoad = recorder("load-cpu"), mlLoad = recorder("load-coreml")
        let cpu = isolated == .sherpaCoreML ? nil : try SherpaRuntime(bundle: bundle, configuration: config, backend: .sherpa, download: nil, cacheRoot: nil, attempt: attempt, recorder: cpuLoad)
        defer { cpu?.close() }
        let ml = isolated == .sherpa ? nil : try SherpaRuntime(bundle: bundle, configuration: config, backend: .sherpaCoreML, download: nil, cacheRoot: nil, attempt: attempt, recorder: mlLoad)
        defer { ml?.close() }
        try save(["sherpa": cpuLoad.value, "coreml": mlLoad.value], output.appendingPathComponent("loads.json"))
        print("MODELS_LOADED cpu=\(cpuLoad.value.modelLoadSeconds) coreml=\(mlLoad.value.modelLoadSeconds)")
        guard !loadOnly else { return }
        let durations: [Double] = [2, 5, 7.5, 7.9, 10, 15.2, 15.7, 20, 20.6]
        let source = durations.map { seconds -> [Float] in
            (0..<Int(seconds * 16_000)).map { voice[$0 % voice.count] }
        }
        let repetitions = isolated == nil ? -2..<7 : 0..<2
        for repetition in repetitions {
            for offset in durations.indices {
                let index = (offset + max(0, repetition)) % durations.count
                let order: [String] = (offset + repetition).isMultiple(of: 2) ? ["sherpa", "coreml"] : ["coreml", "sherpa"]
                for backend in order where (backend == "sherpa" ? cpu != nil : ml != nil) {
                    let row: MicroRow = autoreleasepool {
                        let diagnostic = recorder("micro-\(index)")
                        diagnostic.started()
                        let start = ProcessInfo.processInfo.systemUptime
                        var textHash: String?, failure: String?
                        do {
                            let result = try backend == "sherpa"
                                ? cpu!.recognize(samples: source[index], windowID: "micro", fingerprint: "micro", attempt: attempt, onEvent: { _ in }, recorder: diagnostic)
                                : ml!.recognize(samples: source[index], windowID: "micro", fingerprint: "micro", attempt: attempt, onEvent: { _ in }, recorder: diagnostic)
                            guard !result.text.isEmpty, result.tokens.count == result.timestamps.count else { throw Failure.invalid("Invalid micro result") }
                            textHash = ContentHash.sha256(Data(result.text.utf8))
                        } catch { failure = String(describing: error) }
                        return MicroRow(backend: backend, seconds: durations[index], repetition: repetition,
                            wallSeconds: ProcessInfo.processInfo.systemUptime - start, textSHA256: textHash,
                            error: failure, diagnostic: diagnostic.finished(outcome: failure == nil ? .completed : .failed, attempt: attempt))
                    }
                    try append(row, output.appendingPathComponent("micro.jsonl"))
                }
            }
            print("MICRO repetition=\(repetition)")
        }
    }

    static func pipeline(bundle: SpeechModelBundle, items: [NaturalItem], voice: [Float], output: URL, reverse: Bool,
                         secondsList: [Int] = [60, 600, 3_600], sharedInputs: URL? = nil, coreMLOnly: Bool = false) async throws {
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let backends: [SpeechRecognitionBackend] = coreMLOnly ? [.sherpaCoreML] : reverse ? [.sherpaCoreML, .sherpa] : [.sherpa, .sherpaCoreML]
        for backend in backends {
            let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), recognitionBackend: backend,
                onDiagnostics: { value in diagnostics.withLock { $0.append(value) } }, onEvent: { _ in })
            for item in items {
                diagnostics.withLock { $0.removeAll() }
                let start = ProcessInfo.processInfo.systemUptime
                var text: String?, windows: Int?, failure: String?
                do {
                    let result = try await recognize(engine: engine, inputs: [item.input])
                    text = result.text; windows = result.windows
                } catch { failure = String(describing: error) }
                try append(NaturalRow(backend: backend.rawValue, id: item.id, seconds: Double(item.frames) / 16_000,
                    reference: item.reference, text: text, windows: windows,
                    wallSeconds: ProcessInfo.processInfo.systemUptime - start, error: failure, diagnostics: diagnostics.withLock { $0 }),
                    output.appendingPathComponent("natural.jsonl"))
            }
            print("NATURAL backend=\(backend.rawValue) count=\(items.count)")
            for seconds in secondsList {
                let directory = (sharedInputs ?? output).appendingPathComponent("audio-\(seconds)")
                let inputs: [SpeechAudioInput]
                if FileManager.default.fileExists(atPath: directory.path) {
                    let manifests = try WireJSON.decode([ChunkManifest].self, from: Data(contentsOf: directory.appendingPathComponent("inputs.json")))
                    inputs = try manifests.map { SpeechAudioInput(envelope: try ManifestEnvelope(manifest: $0), audioURL: directory.appendingPathComponent("\($0.frames.start).wav")) }
                } else {
                    guard sharedInputs == nil else { throw Failure.invalid("Shared inputs must already exist") }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let pcm = voice.map { Int16(max(-32_768, min(32_767, ($0 * 32_767).rounded()))) }
                    inputs = try SpeechDiagnosticsRun.makeInputs(voice: pcm, seconds: seconds, directory: directory)
                }
                let repeats = seconds == 3_600 || secondsList.count == 1 ? 1 : 3
                for repetition in 0..<repeats {
                    diagnostics.withLock { $0.removeAll() }
                    let start = ProcessInfo.processInfo.systemUptime
                    var windows: Int?, textHash: String?, failure: String?
                    do {
                        let result = try await recognize(engine: engine, inputs: inputs)
                        windows = result.windows; textHash = ContentHash.sha256(Data(result.text.utf8))
                    } catch { failure = String(describing: error) }
                    let elapsed = ProcessInfo.processInfo.systemUptime - start
                    try append(PipelineRow(backend: backend.rawValue, seconds: seconds, repetition: repetition,
                        wallSeconds: elapsed, windows: windows, textSHA256: textHash, error: failure,
                        diagnostics: diagnostics.withLock { $0 }), output.appendingPathComponent("pipeline.jsonl"))
                    print("PIPELINE backend=\(backend.rawValue) seconds=\(seconds) repetition=\(repetition) wall=\(elapsed) windows=\(windows.map(String.init) ?? "failed") error=\(failure ?? "none")")
                }
            }
        }
    }

    static func recognize(engine: SpeechEngine, inputs: [SpeechAudioInput]) async throws -> (text: String, windows: Int) {
        guard let end = inputs.last?.envelope.manifest.frames.end else { throw Failure.invalid("Empty inputs") }
        let stream = engine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end), readAheadAllowed: false)
        var text = "", windows = 0
        var sequence: SpeechTranscriptionSequence?, anchor: Int64?
        do {
            while let page = try await stream.next() {
                for window in page.batch.windows {
                    if anchor != window.analysisAnchor {
                        if let sequence { await engine.close(sequence) }
                        sequence = try engine.makeTranscriptionSequence(inputs: inputs, anchor: window.analysisAnchor)
                        anchor = window.analysisAnchor
                    }
                    guard let sequence else { throw Failure.invalid("No reader") }
                    let result = try await engine.transcribe(window: window, sequence: sequence)
                    text += result.text; windows += 1
                }
                if page.isFinal { break }
            }
            await stream.waitUntilFinished()
            if let sequence { await engine.close(sequence) }
            return (text, windows)
        } catch {
            stream.cancel(); await stream.waitUntilFinished()
            if let sequence { await engine.close(sequence) }
            throw error
        }
    }

    static func corpusInputs(corpus: URL, output: URL) throws -> ([NaturalItem], [Float]) {
        let manifest = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpus.appendingPathComponent("manifest.json")))
        guard manifest.revision == "70bb2e84b976b7e960aa89f1c648e09c59f894dd", manifest.sampleRate == 16_000 else { throw Failure.invalid("Unexpected public corpus") }
        let sorted = manifest.items.sorted { $0.frames == $1.frames ? $0.id < $1.id : $0.frames < $1.frames }
        let indices = Array(0..<6) + Array((sorted.count / 2 - 3)..<(sorted.count / 2 + 3)) + Array((sorted.count - 8)..<sorted.count)
        let selected = indices.map { sorted[$0] }
        var items: [NaturalItem] = [], samples: [Float] = []
        for item in selected {
            let url = corpus.appendingPathComponent("audio/\(item.filename)")
            guard item.filename == url.lastPathComponent, try ContentHash.sha256(fileAt: url) == item.sha256 else { throw Failure.invalid("Public audio checksum mismatch") }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw Failure.invalid("Unexpected corpus PCM") }
            try file.read(into: buffer)
            guard Int64(buffer.frameLength) == item.frames, let pcm = buffer.floatChannelData?[0] else { throw Failure.invalid("Corpus frame mismatch") }
            samples += Array(UnsafeBufferPointer(start: pcm, count: Int(buffer.frameLength)))
            samples += [Float](repeating: 0, count: 8_000)
            let chunk = try ChunkManifest(sessionID: UUID(), epochID: UUID(), chunkID: UUID(), sourceDeviceID: UUID(),
                sourceBuild: "coreml-benchmark", sequence: 0, frames: FrameRange(start: 0, count: item.frames), timebaseHz: 16_000,
                wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmFloat32, sampleRate: 16_000, channels: 1,
                decodedFrameCount: item.frames, byteCount: item.byteCount, audioSHA256: item.sha256, sourceKind: .fixture)
            items.append(NaturalItem(id: item.id, frames: item.frames, reference: item.reference,
                input: SpeechAudioInput(envelope: try ManifestEnvelope(manifest: chunk), audioURL: url)))
        }
        try save(selected, output.appendingPathComponent("corpus-selection.json"))
        return (items, samples)
    }

    static func recorder(_ id: String) -> SpeechDiagnosticRecorder {
        SpeechDiagnosticRecorder(operation: .transcribe, attemptID: UUID(), windowID: id, fingerprint: "benchmark")
    }
    static func save<T: Encodable>(_ value: T, _ url: URL) throws { try WireJSON.encode(value).write(to: url, options: .withoutOverwriting) }
    static func append<T: Encodable>(_ value: T, _ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .withoutOverwriting) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: WireJSON.encode(value) + Data([10]))
    }
    struct NaturalItem: Sendable { let id: String; let frames: Int64; let reference: String; let input: SpeechAudioInput }
    struct Corpus: Decodable { let revision: String; let sampleRate: Int; let items: [CorpusItem] }
    struct CorpusItem: Codable {
        let id: String; let filename: String; let frames: Int64; let byteCount: Int64; let sha256: String; let reference: String
    }
    struct MicroRow: Encodable {
        let backend: String; let seconds: Double; let repetition: Int; let wallSeconds: Double
        let textSHA256: String?; let error: String?; let diagnostic: SpeechDiagnostics
    }
    struct NaturalRow: Encodable {
        let backend: String; let id: String; let seconds: Double; let reference: String; let text: String?
        let windows: Int?; let wallSeconds: Double; let error: String?; let diagnostics: [SpeechDiagnostics]
    }
    struct PipelineRow: Encodable {
        let backend: String; let seconds: Int; let repetition: Int; let wallSeconds: Double
        let windows: Int?; let textSHA256: String?; let error: String?; let diagnostics: [SpeechDiagnostics]
    }
    enum Failure: Error { case invalid(String) }
}
#endif
