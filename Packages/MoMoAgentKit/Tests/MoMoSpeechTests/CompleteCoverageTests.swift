import AVFoundation
import Foundation
import Testing
import MoMoContracts
import MoMoRecording
@testable import MoMoSpeech

struct CompleteCoverageTests {
    @Test func singleBoundaryAnchorRecoversAWordShiftedIntoNeitherCore() throws {
        let input = try recallInput(frames: 48_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
        let before = try planner.makeWindow(core: FrameRange(start: 0, count: 16_000),
            context: FrameRange(start: 0, count: 20_800), input: input)
        let after = try planner.makeWindow(core: FrameRange(start: 16_000, count: 16_000),
            context: FrameRange(start: 11_200, count: 25_600), input: input)
        let old = SpeechRecognition(windowID: before.id, text: "甲乙", tokens: ["甲", "乙"],
            timestamps: [0.9, 1.01], rawJSON: "{}", configurationFingerprint: before.configurationFingerprint)
        let new = SpeechRecognition(windowID: after.id, text: "甲乙丙", tokens: ["甲", "乙", "丙"],
            timestamps: [0.19, 0.29, 0.5], rawJSON: "{}", configurationFingerprint: after.configurationFingerprint)
        #expect(old.textOwned(by: before) + new.textOwned(by: after, after: (old, before)) == "甲乙丙")
    }
    @Test func gapsOutsideDetectedSpeechNeverBecomeRecognitionWork() throws {
        let input = try recallInput(frames: 960_137)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
        #expect(try planner.continuousWindows(ranges: [], input: input,
            availableThrough: input.modelFrameCount, tailClosed: true).isEmpty)
        let windows = try planner.continuousWindows(ranges: [640_000..<700_000],
            input: input, availableThrough: input.modelFrameCount, tailClosed: true)
        #expect(try FrameRange.union(windows.map(\.coreFrames)) == [
            FrameRange(start: 635_200, count: 69_600)])
        #expect(windows.allSatisfy { $0.coreFrames.count <= 320_000 })
        for (left, right) in zip(windows, windows.dropFirst()) {
            #expect(left.coreFrames.end <= right.coreFrames.start)
        }
    }

    @Test func openTailWaitsForRealContextAndCheckpointContextNeverBecomesCore() throws {
        let input = try recallInput(frames: 640_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
        let windows = try planner.continuousWindows(ranges: [0..<640_000], input: input, availableThrough: 640_000, tailClosed: false)
        #expect(windows.count == 1)
        let resumed = try planner.continuousWindows(ranges: [0..<640_000], input: input, availableThrough: 640_000,
            tailClosed: true, startAt: 320_000)
        #expect(resumed.first?.coreFrames.start == 320_000)
        #expect(resumed.first?.contextFrames.start == 304_000)
        #expect(resumed.last?.coreFrames.end == 640_000)
    }

    @Test func timestampOwnershipPreservesRealRepetitionsAndUnmappableITN() throws {
        let input = try recallInput(frames: 48_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
        let window = try planner.makeWindow(core: FrameRange(start: 4_800, count: 32_000),
            context: FrameRange(start: 0, count: 41_600), input: input)
        func result(_ text: String, _ tokens: [String], _ times: [Float]) -> SpeechRecognition {
            SpeechRecognition(windowID: window.id, text: text, tokens: tokens, timestamps: times,
                rawJSON: "{}", configurationFingerprint: window.configurationFingerprint)
        }
        #expect(result("好好好再见", ["好", "好", "好", "再", "见"], [0.1, 0.4, 1, 2.1, 2.4]).textOwned(by: window) == "好好再")
        #expect(result("9点", ["九", "点"], [0.1, 0.4]).textOwned(by: window) == "9点")
        #expect(result("短句", [], []).textOwned(by: window) == "短句")
    }

    @Test func vadBoundariesPreserveShortUtterancesAndOnlyLongRangesNeedSplitting() throws {
        let input = try recallInput(frames: 1_280_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
        let windows = try planner.continuousWindows(ranges: [32_000..<160_000, 240_000..<1_000_000],
            input: input, availableThrough: input.modelFrameCount, tailClosed: true)
        let cores = windows.map(\.modelCoreFrames)
        // The eight-second utterance ends at its VAD boundary plus the existing padding.
        #expect(cores.first == (try FrameRange(start: 27_200, count: 137_600)))
        #expect(cores.count == 4)
        #expect(try FrameRange.union(cores) == [FrameRange(start: 27_200, count: 137_600),
            FrameRange(start: 235_200, count: 769_600)])
        #expect(cores.allSatisfy { $0.count > 0 && $0.count <= 320_000 })
        #expect(cores.dropFirst().first?.count == 320_000)
        #expect(cores[1].end == cores[2].start && cores[2].end == cores[3].start)
        #expect(windows[1].modelContextFrames.end == cores[1].end + 16_000)
        #expect(windows[2].modelContextFrames.start == cores[2].start - 16_000)
    }

    @Test func overlapAlignmentKeepsRapidRepeatedWordsAndRecoversClockDisagreement() throws {
        let input = try recallInput(frames: 48_000)
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
        let before = try planner.makeWindow(core: FrameRange(start: 0, count: 16_000),
            context: FrameRange(start: 0, count: 20_800), input: input)
        let after = try planner.makeWindow(core: FrameRange(start: 16_000, count: 16_000),
            context: FrameRange(start: 11_200, count: 25_600), input: input)
        let old = SpeechRecognition(windowID: before.id, text: "好好好好", tokens: ["好", "好", "好", "好"],
            timestamps: [0.65, 0.83, 0.99, 1.17], rawJSON: "{}", configurationFingerprint: before.configurationFingerprint)
        let new = SpeechRecognition(windowID: after.id, text: "好好好好", tokens: ["好", "好", "好", "好"],
            timestamps: [0.13, 0.29, 0.47, 0.65], rawJSON: "{}", configurationFingerprint: after.configurationFingerprint)
        #expect(new.textOwned(by: after, after: (old, before)) == "好好")
        let distinct = SpeechRecognition(windowID: before.id, text: "甲乙丙丁", tokens: ["甲", "乙", "丙", "丁"],
            timestamps: [0.65, 0.83, 0.99, 1.17], rawJSON: "{}", configurationFingerprint: before.configurationFingerprint)
        let shifted = SpeechRecognition(windowID: after.id, text: "乙丙丁戊", tokens: ["乙", "丙", "丁", "戊"],
            timestamps: [0.01, 0.1, 0.29, 0.5], rawJSON: "{}", configurationFingerprint: after.configurationFingerprint)
        #expect(shifted.textOwned(by: after, after: (distinct, before)) == "丁戊")
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct CompleteCoverageModelTests {
    @Test(arguments: [false, true])
    func continuousUtteranceSurvivesIncrementalReceipts(restart: Bool) async throws {
        let bundle = try recallBundle()
        let file = try AVAudioFile(forReading: bundle.directory.appendingPathComponent("test_wavs/zh.wav"),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let voice = (0..<Int(buffer.frameLength)).map { Int16(max(-32768, min(32767, (buffer.floatChannelData![0][$0] * 32767).rounded()))) }
        let samples = Array(repeating: voice, count: 8).flatMap { $0 } + [Int16](repeating: 0, count: 3 * 16_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try recallPCM(samples, directory: dir, fileFrames: 19 * 16_000)
        func engine() throws -> SpeechEngine {
            try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(language: "zh"), continuousArchive: true)
        }
        let warm = try engine()
        var resume: SpeechCheckpoint?, previous: (result: SpeechRecognition, window: SpeechWindow)?
        var text = "", trace = "", coverage: [FrameRange] = []
        for count in 1...inputs.count {
            let active = try restart ? engine() : warm
            let prefix = Array(inputs.prefix(count))
            let result = try await active.prepare(inputs: prefix, resume: resume,
                boundary: count == inputs.count ? .captureEnd(Int64(samples.count)) : .open)
            if count == 2 { #expect(!result.windows.isEmpty, "Ongoing speech must publish before recording ends.") }
            for window in result.windows {
                let recognized = try await active.transcribe(window: window, inputs: prefix)
                let owned = active.archiveText(recognized, window: window, after: previous)
                trace += "\ncore=\(window.modelCoreFrames) context=\(window.modelContextFrames) all=\(recognized.text) owned=\(owned)"
                text += owned
                previous = (recognized, window)
            }
            coverage += result.analyzedCoverage
            resume = result.checkpoint ?? resume
        }
        #expect(try FrameRange.union(coverage) == [FrameRange(start: 0, count: Int64(samples.count))])
        #expect(text.filter { $0.isLetter || $0.isNumber } == String(repeating: "开放时间早上9点至下午5点", count: 8), "Incremental transcript: \(text)\(trace)")
    }

    @Test(arguments: [false, true])
    func receivedPrefixRetainsUndecidedSpeechAcrossResume(restart: Bool) async throws {
        let bundle = try recallBundle()
        let file = try AVAudioFile(forReading: bundle.directory.appendingPathComponent("test_wavs/zh.wav"),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let voice = (0..<Int(buffer.frameLength)).map { Int16(max(-32768, min(32767, (buffer.floatChannelData![0][$0] * 32767).rounded()))) }
        let voiceStart = 20 * 16_000 - 1_600
        let samples = [Int16](repeating: 0, count: voiceStart) + voice + [Int16](repeating: 0, count: 3 * 16_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try recallPCM(samples, directory: dir, fileFrames: 20 * 16_000)
        func engine() throws -> SpeechEngine {
            try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(language: "zh"), continuousArchive: true)
        }
        let firstEngine = try engine()
        let prefix = try await firstEngine.prepare(inputs: [inputs[0]], boundary: .open)
        #expect(prefix.waitingForMoreAudio)
        let checkpoint = try #require(prefix.checkpoint)
        #expect(checkpoint.sourceFrame < voiceStart, "An undecided onset cannot be durably classified as silence.")
        let resumed = try restart ? engine() : firstEngine
        let result = try await resumed.prepare(inputs: inputs, resume: checkpoint,
            boundary: .captureEnd(Int64(samples.count)))
        #expect(try FrameRange.union(prefix.analyzedCoverage + result.analyzedCoverage) == [FrameRange(start: 0, count: Int64(samples.count))])
        var text = ""
        for window in result.windows { text += try await resumed.transcribe(window: window, inputs: inputs).text }
        #expect(text.filter { $0.isLetter || $0.isNumber } == "开放时间早上9点至下午5点")
    }
    @Test func normalSpeechWithNonzeroBackgroundMatchesExistingSpeechSegmentationAndSkipsNoise() async throws {
        let bundle = try recallBundle()
        let file = try AVAudioFile(forReading: bundle.directory.appendingPathComponent("test_wavs/zh.wav"),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        var seed: UInt64 = 51
        var samples = (0..<(140 * 16_000)).map { _ -> Int16 in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int16(Int((seed >> 32) % 127) - 63)
        }
        for start in [39 * 16_000, 89 * 16_000] {
            for i in 0..<Int(buffer.frameLength) {
                samples[start + i] += Int16((buffer.floatChannelData![0][i] * 32_767).rounded())
            }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try recallPCM(samples, directory: dir, fileFrames: 40 * 16_000)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(language: "zh"), continuousArchive: true)
        try engine.setVoiceActivityThreshold(0.25)
        let batch = try await engine.prepare(inputs: inputs, boundary: .receivedSnapshot(Int64(samples.count)))
        #expect(batch.windows.reduce(0) { $0 + $1.modelCoreFrames.count } < samples.count / 2)
        var text = ""
        var previous: (result: SpeechRecognition, window: SpeechWindow)?
        for window in batch.windows {
            let result = try await engine.transcribe(window: window, inputs: inputs)
            text += engine.archiveText(result, window: window, after: previous)
            previous = (result, window)
        }
        // Compare with the existing Silero-only path. This isolates changes to
        // archive selection from ASR sensitivity to noisy utterance edges.
        let baseline = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(language: "zh"))
        try baseline.setVoiceActivityThreshold(0.25)
        var resume: SpeechCheckpoint?, baselineText = ""
        repeat {
            let page = try await baseline.prepare(inputs: inputs, resume: resume,
                boundary: .receivedSnapshot(Int64(samples.count)))
            for window in page.windows {
                baselineText += try await baseline.transcribe(window: window, inputs: inputs).text
            }
            let next = try #require(page.checkpoint)
            #expect(next.sourceFrame > (resume?.sourceFrame ?? 0))
            resume = next
        } while resume!.sourceFrame < samples.count
        let normalized = text.filter { $0.isLetter || $0.isNumber }
        #expect(normalized == baselineText.filter { $0.isLetter || $0.isNumber })
        // Known SenseVoice homophones (开饭/派饭) on these synthetic noisy boundaries.
        // Clean fixtures check the actual reference word 开放, not this accepted model error.
        #expect([
            String(repeating: "开饭时间早上9点至下午5点", count: 2),
            "开饭时间早上9点至下午5点派饭时间早上9点至下午5点"
        ].contains(normalized))
    }

    @Test(arguments: [false, true])
    func digitalSilenceAndNonzeroNoiseSkipASRWithoutLosingCoverage(noise: Bool) async throws {
        let bundle = try recallBundle()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var seed: UInt64 = 42
        let samples = (0..<960_137).map { _ -> Int16 in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return noise ? Int16(Int((seed >> 32) % 127) - 63) : 0
        }
        let inputs = try recallPCM(samples, directory: dir)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), continuousArchive: true)
        let previousModel = try SpeechModelManifest(asrSHA256: bundle.manifest.asrSHA256,
            tokensSHA256: bundle.manifest.tokensSHA256,
            vadSHA256: "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
        let previousBundle = SpeechModelBundle(directory: bundle.directory, manifest: previousModel)
        #expect(engine.previousConfigurationFingerprints == [
            try bundle.fingerprint(configuration: SpeechConfiguration(), rule: "silero6-bounded-speech-v5"),
            try bundle.fingerprint(configuration: SpeechConfiguration(), rule: "silero6-pause-aligned-v4"),
            try bundle.fingerprint(configuration: SpeechConfiguration(), rule: "silero6-speech-only-v3"),
            try bundle.fingerprint(configuration: SpeechConfiguration(), rule: "silero6-selective-archive-v2"),
            try bundle.fingerprint(configuration: SpeechConfiguration(), rule: "silero6-complete-coverage-v1"),
            try previousBundle.fingerprint(configuration: SpeechConfiguration(), rule: "silero6-bounded-speech-v5"),
            try previousBundle.fingerprint(configuration: SpeechConfiguration())].filter { $0 != engine.configurationFingerprint })
        #expect(!engine.previousConfigurationFingerprints.contains(engine.configurationFingerprint))
        try engine.setVoiceActivityThreshold(0.25)
        let direct = try await engine.prepare(inputs: inputs, boundary: .receivedSnapshot(960_137))
        #expect(direct.windows.isEmpty)
        #expect(direct.noSpeechCoverage == [try FrameRange(start: 0, count: 960_137)])
        let cold = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), continuousArchive: true)
        try cold.setVoiceActivityThreshold(0.25)
        var windows: [SpeechWindow] = [], coverage: [FrameRange] = []
        let stream = cold.prepareStream(inputs: inputs, boundary: .receivedSnapshot(960_137))
        while let page = try await stream.next() {
            windows += page.batch.windows
            coverage += page.batch.noSpeechCoverage
        }
        #expect(windows.isEmpty)
        #expect(try FrameRange.union(coverage) == direct.analyzedCoverage)
    }

    @Test(arguments: [1, 8])
    func utterancesCrossPhysicalFilesAndLongRecognitionWindows(repetitions: Int) async throws {
        let bundle = try recallBundle()
        let file = try AVAudioFile(forReading: bundle.directory.appendingPathComponent("test_wavs/zh.wav"),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let voice = (0..<Int(buffer.frameLength)).map { Int16(max(-32768, min(32767, (buffer.floatChannelData![0][$0] * 32767).rounded()))) }
        let repeated = Array(repeating: voice, count: repetitions).flatMap { $0 }
        let samples = [Int16](repeating: 0, count: 17 * 16_000) + repeated + [Int16](repeating: 0, count: 16_000)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inputs = try recallPCM(samples, directory: dir, fileFrames: 19 * 16_000)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(language: "zh"), continuousArchive: true)
        try engine.setVoiceActivityThreshold(0.25)
        let batch = try await engine.prepare(inputs: inputs, boundary: .receivedSnapshot(Int64(samples.count)))
        var text = ""
        var previous: (result: SpeechRecognition, window: SpeechWindow)?
        for window in batch.windows {
            let result = try await engine.transcribe(window: window, inputs: inputs)
            text += engine.archiveText(result, window: window, after: previous)
            previous = (result, window)
        }
        let normalized = text.filter { $0.isLetter || $0.isNumber }
        #expect(normalized == String(repeating: "开放时间早上9点至下午5点", count: repetitions), "Boundary transcript: \(text), cores: \(batch.windows.map(\.modelCoreFrames)), contexts: \(batch.windows.map(\.modelContextFrames))")
    }
}

private func recallInput(frames: Int64) throws -> SpeechInputSet {
    let m = try ChunkManifest(sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "test",
        sequence: 0, frames: FrameRange(start: 0, count: frames), timebaseHz: 16_000,
        wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16,
        sampleRate: 16_000, channels: 1, decodedFrameCount: frames, byteCount: frames * 2 + 44,
        audioSHA256: String(repeating: "a", count: 64), sourceKind: .fixture)
    return try SpeechInputSet([SpeechAudioInput(envelope: ManifestEnvelope(manifest: m),
        audioURL: URL(fileURLWithPath: "/unused.wav"))], anchor: 0)
}

private func recallBundle() throws -> SpeechModelBundle {
    try SpeechModelBundle.load(from: URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"])))
}

private func recallPCM(_ samples: [Int16], directory: URL, fileFrames: Int = 960_000) throws -> [SpeechAudioInput] {
    var writer = try PCM16SegmentWriter(directory: directory, sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
        sourceBuild: "test", sourceKind: .fixture, sampleRate: 16_000, targetFrames: fileFrames,
        wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0)
    var chunks = try writer.append(samples)
    if let tail = try writer.finish() { chunks.append(tail) }
    return chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
}
