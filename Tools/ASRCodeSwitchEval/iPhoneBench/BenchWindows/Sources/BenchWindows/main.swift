// BenchWindows: cut real archive recordings into the iPhone app's archive recognition windows.
//
// Usage (from the repository root; needs Vendor/SherpaOnnx/Binaries and an app Speech bundle):
//   swift build -c release --package-path Tools/ASRCodeSwitchEval/iPhoneBench/BenchWindows \
//       --scratch-path tmp_agent_output/iphone-bench/benchwindows-build
//   BenchWindows --recordings DIR --speech-bundle DIR --output DIR [--threshold 0.25] [--target-minutes 30]
//
// DIR for --recordings is a copy of the app container's Documents/recordings (chunk .m4a plus
// .m4a.manifest.json). Every epoch goes through SpeechEngine.prepare with the iPhone app's settings:
// SpeechConfiguration() defaults, continuousArchive (Silero v6, cut-and-merge v6 planner) and the app's
// default VAD threshold 0.25 (PhoneSpeechSettings.defaultVADThreshold). Windows are then sampled evenly
// across all epochs until the selected context audio reaches --target-minutes.
//
// Output (private audio; keep it under ignored tmp_agent_output/):
//   index.json  selected windows: offset/count into audio.f32, coreOffset/coreCount inside the window
//   audio.f32   little-endian Float32 16 kHz mono context samples, concatenated
//   stats.json  recorded seconds, window counts and seconds for all epochs (speech ratio for extrapolation)

import AVFoundation
import Foundation
import MoMoContracts
import MoMoSpeech

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var options: [String: String] = [:]
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    guard argument.hasPrefix("--"), let value = arguments.first else { fail("Unexpected argument \(argument)") }
    arguments.removeFirst()
    options[String(argument.dropFirst(2))] = value
}
func path(_ key: String) -> URL {
    guard let value = options[key] else { fail("Missing --\(key)") }
    return URL(fileURLWithPath: value).standardizedFileURL
}
let recordings = path("recordings"), output = path("output")
let threshold = Float(options["threshold"] ?? "0.25")!
let targetSeconds = Double(options["target-minutes"] ?? "30")! * 60

struct Chunk { let input: SpeechAudioInput; let manifest: ChunkManifest }
var epochs: [UUID: [Chunk]] = [:]
for url in FileManager.default.enumerator(at: recordings, includingPropertiesForKeys: nil)!.allObjects as! [URL]
where url.lastPathComponent.hasSuffix(".m4a.manifest.json") {
    // Earphone chunks carry SourceKind "phone", which this branch's MoMoContracts predates. MoMoSpeech
    // never reads the source kind, so map it to "watch" in memory only.
    let data = Data(try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "\"sourceKind\":\"phone\"", with: "\"sourceKind\":\"watch\"").utf8)
    let envelope = try ManifestEnvelope(manifestData: data, manifestSHA256: ContentHash.sha256(data))
    let audio = URL(fileURLWithPath: String(url.path.dropLast(".manifest.json".count)))
    guard FileManager.default.fileExists(atPath: audio.path) else { continue }
    epochs[envelope.manifest.epochID, default: []].append(
        Chunk(input: SpeechAudioInput(envelope: envelope, audioURL: audio), manifest: envelope.manifest))
}

let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: path("speech-bundle")),
    configuration: SpeechConfiguration(), continuousArchive: true, recognitionBackend: .sherpa)
try engine.setVoiceActivityThreshold(threshold)

func decode(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { fail("Expected 16 kHz mono AAC: \(url.path)") }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

struct Planned { let window: SpeechWindow; let chunks: [Chunk]; let wallClock: Date }
var planned: [Planned] = []
var recordedFrames: Int64 = 0, failedEpochs = 0
for (epochID, unsorted) in epochs.sorted(by: { $0.value[0].manifest.wallClockAnchor < $1.value[0].manifest.wallClockAnchor }) {
    let chunks = unsorted.sorted { $0.manifest.frames.start < $1.manifest.frames.start }
    let end = chunks.last!.manifest.frames.end
    recordedFrames += chunks.reduce(0) { $0 + $1.manifest.frames.count }
    do {
        let batch = try await engine.prepare(inputs: chunks.map(\.input), boundary: .captureEnd(end))
        planned += batch.windows.map { Planned(window: $0, chunks: chunks, wallClock: chunks[0].manifest.wallClockAnchor) }
    } catch {
        failedEpochs += 1
        FileHandle.standardError.write(Data("epoch \(epochID): \(error)\n".utf8))
    }
}
guard !planned.isEmpty else { fail("No windows") }

let contextSeconds = planned.reduce(0.0) { $0 + Double($1.window.contextFrames.count) / 16_000 }
let coreSeconds = planned.reduce(0.0) { $0 + Double($1.window.coreFrames.count) / 16_000 }
// Even spacing keeps morning/evening, quiet/busy recordings in proportion.
let stride = max(1.0, contextSeconds / targetSeconds)
var selected: [Planned] = []
var cursor = 0.0
while Int(cursor) < planned.count { selected.append(planned[Int(cursor)]); cursor += stride }

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var audio = Data(), index: [[String: Any]] = [], cache: [URL: [Float]] = [:], offset = 0
for item in selected {
    let window = item.window
    var samples = [Float](repeating: 0, count: Int(window.contextFrames.count))
    for chunk in item.chunks where chunk.manifest.frames.end > window.contextFrames.start
        && chunk.manifest.frames.start < window.contextFrames.end {
        if cache[chunk.input.audioURL] == nil {
            if cache.count >= 4 { cache.removeAll() }
            cache[chunk.input.audioURL] = try decode(chunk.input.audioURL)
        }
        let decoded = cache[chunk.input.audioURL]!
        let from = max(chunk.manifest.frames.start, window.contextFrames.start)
        let to = min(chunk.manifest.frames.end, window.contextFrames.end, chunk.manifest.frames.start + Int64(decoded.count))
        guard from < to else { continue }
        for frame in from..<to {
            samples[Int(frame - window.contextFrames.start)] = decoded[Int(frame - chunk.manifest.frames.start)]
        }
    }
    samples.withUnsafeBufferPointer { audio.append(Data(buffer: $0)) }
    index.append(["uid": window.id, "sessionID": window.sessionID.uuidString, "epochID": window.epochID.uuidString,
                  "offset": offset, "count": samples.count,
                  "coreOffset": Int(window.coreFrames.start - window.contextFrames.start),
                  "coreCount": Int(window.coreFrames.count)])
    offset += samples.count
}
try audio.write(to: output.appendingPathComponent("audio.f32"))
func write(_ object: Any, _ name: String) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent(name))
}
try write(index, "index.json")
let selectedContext = selected.reduce(0.0) { $0 + Double($1.window.contextFrames.count) / 16_000 }
let selectedCore = selected.reduce(0.0) { $0 + Double($1.window.coreFrames.count) / 16_000 }
try write(["vadThreshold": threshold, "fingerprint": engine.configurationFingerprint,
           "epochs": epochs.count, "failedEpochs": failedEpochs, "recordedSeconds": Double(recordedFrames) / 16_000,
           "windows": planned.count, "windowContextSeconds": contextSeconds, "windowCoreSeconds": coreSeconds,
           "selectedWindows": selected.count, "selectedContextSeconds": selectedContext,
           "selectedCoreSeconds": selectedCore], "stats.json")
print("windows \(planned.count) (\(Int(coreSeconds)) s core of \(Int(Double(recordedFrames) / 16_000)) s recorded); "
      + "selected \(selected.count), \(Int(selectedContext)) s context")
