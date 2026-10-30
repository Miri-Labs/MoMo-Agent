import Foundation
import SherpaOnnxC
import MoMoSherpaBridge

/// Same thread count as the app's SpeechConfiguration() and the Mac runs (models.py THREADS).
let benchThreads: Int32 = 2

enum ModelKind { case senseVoice, funASRNano, fireRed(encoder: String, decoder: String), paraformer,
                 offlineTransducer, onlineTransducer(tailSeconds: Double) }

struct BenchModel {
    let key: String
    let kind: ModelKind
    /// The app decodes SenseVoice archive windows two at a time (SpeechEngine.archiveBatchSize).
    var batchSize: Int { if case .senseVoice = kind { 2 } else { 1 } }
    /// Nano receives only the window core (SpeechEngine.recognizeArchive useCoreSlice).
    var coreOnly: Bool { if case .funASRNano = kind { true } else { false } }

    static let all: [BenchModel] = [
        .init(key: "sensevoice-int8-20240717", kind: .senseVoice),
        .init(key: "funasr-nano-int8-20251230", kind: .funASRNano),
        .init(key: "fireredasr2-aed-int8-20260226", kind: .fireRed(encoder: "encoder.int8.onnx", decoder: "decoder.int8.onnx")),
        .init(key: "fireredasr2-aed-int4-b32", kind: .fireRed(encoder: "encoder.onnx", decoder: "decoder.onnx")),
        .init(key: "fireredasr2-aed-int4-b128", kind: .fireRed(encoder: "encoder.onnx", decoder: "decoder.onnx")),
        .init(key: "x-asr-offline-punct-int8-20260603", kind: .offlineTransducer),
        // models.py uses 2 s of tail padding (the 0.66 s sherpa default drops final words).
        .init(key: "x-asr-streaming-480ms-punct-int8-20260605", kind: .onlineTransducer(tailSeconds: 2)),
        .init(key: "paraformer-zh-int8-20240309", kind: .paraformer),
    ]
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

protocol Recognizer: AnyObject {
    /// Runtime path, recorded in result.json.
    var runtime: String { get }
    func recognize(_ batch: [[Float]]) throws -> [String]
}

/// Provider string in the app's format (SherpaRuntime.provider): "cpu:<file>" or "coreml:<file>",
/// ORT spinning off; SenseVoice adds the app's Core ML EP options.
func providerString(coreML: Bool, cacheDirectory: URL) throws -> String {
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    var lines = ["SessionConfig.session.intra_op.allow_spinning=0", "SessionConfig.session.inter_op.allow_spinning=0"]
    if coreML {
        lines += ["ModelFormat=MLProgram", "MLComputeUnits=CPUAndNeuralEngine", "RequireStaticInputShapes=1",
                  "ModelCacheDirectory=\(cacheDirectory.path)"]
    }
    let url = cacheDirectory.appendingPathComponent(coreML ? "sherpaCoreML.config" : "sherpa.config")
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    return "\(coreML ? "coreml" : "cpu"):\(url.path)"
}

/// Keeps C strings alive for the duration of a config call.
final class CStrings {
    private var pointers: [UnsafeMutablePointer<CChar>] = []
    func callAsFunction(_ value: String) -> UnsafePointer<CChar> {
        let pointer = strdup(value)!
        pointers.append(pointer)
        return UnsafePointer(pointer)
    }
    deinit { pointers.forEach { free($0) } }
}

func makeRecognizer(_ model: BenchModel, directory: URL, cache: URL) throws -> Recognizer {
    switch model.kind {
    case .funASRNano: return try NanoRecognizer(directory: directory)
    case .onlineTransducer(let tail): return try OnlineRecognizer(directory: directory, cache: cache, tailSeconds: tail)
    default: return try OfflineRecognizer(model, directory: directory, cache: cache)
    }
}

final class OfflineRecognizer: Recognizer {
    let runtime: String
    private let recognizer: OpaquePointer

    init(_ model: BenchModel, directory: URL, cache: URL) throws {
        let s = CStrings()
        func file(_ name: String) -> UnsafePointer<CChar> { s(directory.appendingPathComponent(name).path) }
        var coreML = false
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.decoding_method = s("greedy_search")
        config.model_config.num_threads = benchThreads
        switch model.kind {
        case .senseVoice:
            coreML = true
            config.model_config.tokens = file("tokens.txt")
            config.model_config.sense_voice.model = file("model.int8.onnx")
            config.model_config.sense_voice.language = s("auto")
            config.model_config.sense_voice.use_itn = 1
        case .fireRed(let encoder, let decoder):
            config.model_config.tokens = file("tokens.txt")
            config.model_config.fire_red_asr.encoder = file(encoder)
            config.model_config.fire_red_asr.decoder = file(decoder)
        case .paraformer:
            config.model_config.tokens = file("tokens.txt")
            config.model_config.paraformer.model = file("model.int8.onnx")
        case .offlineTransducer:
            config.model_config.tokens = file("tokens.txt")
            config.model_config.transducer.encoder = file("encoder-epoch-99-avg-1.int8.onnx")
            config.model_config.transducer.decoder = file("decoder-epoch-99-avg-1.onnx")
            config.model_config.transducer.joiner = file("joiner-epoch-99-avg-1.int8.onnx")
        default: throw BenchError("not an offline model")
        }
        let provider = try providerString(coreML: coreML, cacheDirectory: cache)
        config.model_config.provider = s(provider)
        runtime = "app sherpa-onnx 1.13.8 (MoMoSherpaBridge, ORT 1.28.2) provider=\(coreML ? "coreml CPUAndNeuralEngine static-shapes" : "cpu")"
        var error = [CChar](repeating: 0, count: 2048)
        guard let created = MoMoCreateOfflineRecognizer(&config, &error, error.count) else {
            throw BenchError("load: " + String(cString: error))
        }
        recognizer = created
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    func recognize(_ batch: [[Float]]) throws -> [String] {
        var streams: [OpaquePointer?] = []
        defer { streams.forEach { if let stream = $0 { SherpaOnnxDestroyOfflineStream(stream) } } }
        var error = [CChar](repeating: 0, count: 2048)
        for samples in batch {
            guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { throw BenchError("stream") }
            streams.append(stream)
            let accepted = samples.withUnsafeBufferPointer {
                MoMoAcceptWaveform(stream, $0.baseAddress, Int32($0.count), &error, error.count)
            }
            guard accepted == 1 else { throw BenchError("input: " + String(cString: error)) }
        }
        guard MoMoDecodeOfflineStreams(recognizer, &streams, Int32(streams.count), &error, error.count) == 1 else {
            throw BenchError("decode: " + String(cString: error))
        }
        return try streams.map { stream in
            guard let stream, let result = SherpaOnnxGetOfflineStreamResult(stream) else { throw BenchError("result") }
            defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
            return result.pointee.text.map { String(cString: $0) } ?? ""
        }
    }
}

/// The app's own FunASR-Nano runtime (FunASRNano.cpp): language automatic, ITN on.
final class NanoRecognizer: Recognizer {
    let runtime = "app MoMoSherpaBridge FunASRNano.cpp (ORT 1.28.2 CPU)"
    private let nano: OpaquePointer

    init(directory: URL) throws {
        var error = [CChar](repeating: 0, count: 2048)
        func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
        guard let created = MoMoCreateFunASRNanoRuntime(path("encoder_adaptor.int8.onnx"), path("llm.int8.onnx"),
            path("embedding.int8.onnx"), path("Qwen3-0.6B"), benchThreads, &error, error.count) else {
            throw BenchError("load: " + String(cString: error))
        }
        nano = created
    }

    deinit { MoMoDestroyFunASRNanoRuntime(nano) }

    func recognize(_ batch: [[Float]]) throws -> [String] {
        try batch.map { samples in
            var error = [CChar](repeating: 0, count: 2048)
            var result: UnsafeMutablePointer<MoMoFunASRNanoResult>?
            let status = samples.withUnsafeBufferPointer {
                MoMoTranscribeFunASRNano(nano, $0.baseAddress, Int32($0.count), "", 1, nil, nil, &result, &error, error.count)
            }
            defer { if let result { MoMoDestroyFunASRNanoResult(result) } }
            guard status == 1, let text = result?.pointee.text else { throw BenchError("decode: " + String(cString: error)) }
            return String(cString: text)
        }
    }
}

/// Streaming transducer through sherpa's C API directly (the app wrapper is offline-only). Like models.py:
/// whole window pushed through, 2 s of zero padding, input finished, decode while ready.
final class OnlineRecognizer: Recognizer {
    let runtime = "app sherpa-onnx 1.13.8 C API online recognizer (ORT 1.28.2 CPU; no exception guard)"
    private let recognizer: OpaquePointer
    private let tail: [Float]

    init(directory: URL, cache: URL, tailSeconds: Double) throws {
        let s = CStrings()
        func file(_ name: String) -> UnsafePointer<CChar> { s(directory.appendingPathComponent(name).path) }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = file("encoder.int8.onnx")
        config.model_config.transducer.decoder = file("decoder.onnx")
        config.model_config.transducer.joiner = file("joiner.int8.onnx")
        config.model_config.tokens = file("tokens.txt")
        config.model_config.num_threads = benchThreads
        config.model_config.provider = s(try providerString(coreML: false, cacheDirectory: cache))
        config.decoding_method = s("greedy_search")
        config.enable_endpoint = 0
        guard let created = SherpaOnnxCreateOnlineRecognizer(&config) else { throw BenchError("load: invalid online config") }
        recognizer = created
        tail = [Float](repeating: 0, count: Int(tailSeconds * 16_000))
    }

    deinit { SherpaOnnxDestroyOnlineRecognizer(recognizer) }

    func recognize(_ batch: [[Float]]) throws -> [String] {
        try batch.map { samples in
            guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else { throw BenchError("stream") }
            defer { SherpaOnnxDestroyOnlineStream(stream) }
            samples.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count)) }
            tail.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress, Int32($0.count)) }
            SherpaOnnxOnlineStreamInputFinished(stream)
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 { SherpaOnnxDecodeOnlineStream(recognizer, stream) }
            guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { throw BenchError("result") }
            defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
            return result.pointee.text.map { String(cString: $0) } ?? ""
        }
    }
}
