import AVFoundation
import Foundation
import Testing
import os
import MoMoContracts
import MoMoRecording
@testable import MoMoSpeech

@Suite(.serialized)
struct SegmentationStudyTests {
    struct Row: Codable {
        let fixture: String, variant: String, text: String
        let referenceCharacters: Int, errors: Int, windows: Int
        let selectedSeconds: Double, inputSeconds: Double, decodeSeconds: Double
        let contexts: [[Double]]
    }

    @Test func compareBoundaries() async throws {
        let env = ProcessInfo.processInfo.environment
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: #require(env["MOMO_SPEECH_MODEL_DIRECTORY"])))
        let file = try AVAudioFile(forReading: bundle.directory.appendingPathComponent("test_wavs/zh.wav"),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let voice = (0..<Int(pcm.frameLength)).map { Int16(max(-32768, min(32767, (pcm.floatChannelData![0][$0] * 32767).rounded()))) }
        let expected = "开放时间早上9点至下午5点"
        let root = URL(fileURLWithPath: try #require(env["MOMO_SEGMENTATION_OUTPUT"]))
        var rows: [Row] = []
        for fixture in ["short-noise", "long-continuous", "long-pauses"] {
            if env["MOMO_SEGMENTATION_SHORT_ONLY"] == "1", fixture != "short-noise" { continue }
            let repeats = fixture == "short-noise" ? 2 : 24
            var samples: [Int16] = [], pauses: [Int64] = []
            if fixture == "short-noise" {
                var seed: UInt64 = 51
                samples = (0..<(140 * 16_000)).map { _ in
                    seed = seed &* 6_364_136_223_846_793_005 &+ 1
                    return Int16(Int((seed >> 32) % 127) - 63)
                }
                for start in [39 * 16_000, 89 * 16_000] {
                    for i in voice.indices { samples[start + i] += voice[i] }
                }
            } else {
                for index in 0..<repeats {
                    samples += voice
                    if fixture == "long-pauses", index + 1 < repeats {
                        pauses.append(Int64(samples.count + 2_400))
                        samples += [Int16](repeating: 0, count: 4_800)
                    }
                }
            }
            var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent(fixture),
                sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "study",
                sourceKind: .fixture, sampleRate: 16_000, targetFrames: 60 * 16_000,
                wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0)
            var chunks = try writer.append(samples)
            if let tail = try writer.finish() { chunks.append(tail) }
            let inputs = chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
            let variants = fixture == "short-noise"
                ? ["20s-pad300", "30s-pad300", "20s-pad100", "20s-pad0", "20s-left100-right300", "20s-left300-right100", "original-utterance"]
                : (fixture == "long-pauses" ? ["20s-pad300", "30s-pad300", "20s-known-pauses"] : ["20s-pad300", "30s-pad300"])
            for variant in variants {
                let pad: Int64 = variant == "20s-pad100" ? 1_600 : (variant == "20s-pad0" ? 0 : 4_800)
                let maximum: Int64 = variant.hasPrefix("30s") ? 480_000 : 320_000
                let config = try SpeechConfiguration(language: "zh", paddingFrames: pad, maximumCoreFrames: maximum)
                let metrics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
                let engine = try SpeechEngine(bundle: bundle, configuration: config, continuousArchive: true,
                    onDiagnostics: { event in metrics.withLock { $0.append(event) } }, onEvent: { _ in })
                try engine.setVoiceActivityThreshold(0.25)
                try await engine.warmUp()
                metrics.withLock { $0.removeAll() }
                let batch = try await engine.prepare(inputs: inputs, boundary: .receivedSnapshot(Int64(samples.count)))
                var windows = batch.windows
                let input = try SpeechInputSet(inputs, anchor: 0)
                let planner = WindowPlanner(configuration: config, fingerprint: engine.configurationFingerprint)
                if variant == "original-utterance" {
                    windows = try [39 * 16_000, 89 * 16_000].map { start in
                        let range = try FrameRange(start: Int64(start), count: Int64(voice.count))
                        return try planner.makeWindow(core: range, context: range, input: input)
                    }
                }
                if variant == "20s-left100-right300" || variant == "20s-left300-right100" {
                    windows = try windows.map { window in
                        let left = window.modelCoreFrames.start + (variant == "20s-left100-right300" ? 3_200 : 0)
                        let right = window.modelCoreFrames.end - (variant == "20s-left300-right100" ? 3_200 : 0)
                        let range = try FrameRange(start: left, count: right - left)
                        return try planner.makeWindow(core: range, context: range, input: input)
                    }
                }
                if variant == "20s-known-pauses" {
                    windows = []
                    for part in try FrameRange.union(batch.windows.map(\.modelCoreFrames)) {
                        var start = part.start
                        while start < part.end {
                            let limit = min(part.end, start + maximum)
                            let cut = limit == part.end ? limit : (pauses.last { $0 >= start + 15 * 16_000 && $0 <= limit } ?? limit)
                            let left = max(part.start, start - 16_000), right = min(part.end, cut + 16_000)
                            windows.append(try planner.makeWindow(core: FrameRange(start: start, count: cut - start),
                                context: FrameRange(start: left, count: right - left), input: input))
                            start = cut
                        }
                    }
                }
                var text = "", previous: (result: SpeechRecognition, window: SpeechWindow)?
                for window in windows {
                    let result = try await engine.transcribe(window: window, inputs: inputs)
                    text += engine.archiveText(result, window: window, after: previous)
                    previous = (result, window)
                }
                let normalized = text.filter { $0.isLetter || $0.isNumber }
                let reference = String(repeating: expected, count: repeats)
                let observations = metrics.withLock { $0 }
                rows.append(Row(fixture: fixture, variant: variant, text: normalized,
                    referenceCharacters: reference.count, errors: distance(normalized, reference), windows: windows.count,
                    selectedSeconds: Double(windows.reduce(0) { $0 + $1.modelCoreFrames.count }) / 16_000,
                    inputSeconds: Double(observations.reduce(0) { $0 + ($1.recognitionInputModelFrames ?? 0) }) / 16_000,
                    decodeSeconds: observations.reduce(0) { $0 + $1.nativeDecodeSeconds },
                    contexts: windows.map { [Double($0.modelContextFrames.start) / 16_000, Double($0.modelContextFrames.end) / 16_000] }))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: root.appendingPathComponent("results.json"))
    }

    func distance(_ actual: String, _ expected: String) -> Int {
        let a = Array(actual), b = Array(expected)
        var prior = Array(0...b.count)
        for (i, ch) in a.enumerated() {
            var row = [i + 1] + [Int](repeating: 0, count: b.count)
            for j in b.indices { row[j + 1] = min(row[j] + 1, prior[j + 1] + 1, prior[j] + (ch == b[j] ? 0 : 1)) }
            prior = row
        }
        return prior[b.count]
    }
}
