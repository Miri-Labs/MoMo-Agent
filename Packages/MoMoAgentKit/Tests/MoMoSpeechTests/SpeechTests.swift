import AVFoundation
@preconcurrency import CoreML
import Foundation
import os
import Testing
import MoMoContracts
import MoMoRecording
@testable import MoMoSpeech

@Test func modelFingerprintIncludesRecognitionAndAnalysisConfiguration() throws {
    let manifest = try SpeechModelManifest(asrSHA256: String(repeating: "a", count: 64),
                                           tokensSHA256: String(repeating: "b", count: 64),
                                           vadSHA256: String(repeating: "c", count: 64))
    let bundle = SpeechModelBundle(directory: URL(fileURLWithPath: "/unused"), manifest: manifest)
    let normal = try bundle.fingerprint(configuration: SpeechConfiguration())
    #expect(try normal == bundle.fingerprint(configuration: SpeechConfiguration()))
    #expect(try normal != bundle.fingerprint(configuration: SpeechConfiguration(useITN: false)))
    #expect(try normal != bundle.fingerprint(configuration: SpeechConfiguration(threshold: 0.6)))
    #expect(throws: SpeechError.invalidConfiguration) { try SpeechConfiguration(threads: 0) }
}

@Test func paddingUsesSilenceMidpointAndLongSpeechUsesStableDisjointCores() throws {
    let input = try planningInputs(frameCounts: [960_000, 160_000])
    let set = try SpeechInputSet(input, anchor: 0)
    let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
    let adjacent = try planner.windows(ranges: [16_000..<32_000, 38_000..<48_000], input: set,
                                       availableThrough: 64_000, tailClosed: true)
    #expect(adjacent.count == 2)
    #expect(adjacent[0].modelContextFrames.end == 35_000)
    #expect(adjacent[1].modelContextFrames.start == 35_000)
    let open = try planner.windows(ranges: [32_000..<720_000], input: set,
                                   availableThrough: 730_000, tailClosed: false)
    let closed = try planner.windows(ranges: [32_000..<730_000], input: set,
                                     availableThrough: 740_000, tailClosed: true)
    #expect(open.count == 2)
    #expect(open == Array(closed.prefix(2)))
    #expect(open[0].coreFrames.end == open[1].coreFrames.start)
    #expect(open.allSatisfy { $0.modelCoreFrames.count == 320_000 })
}

@Test func inputGapIsNotSyntheticSilence() throws {
    let inputs = try planningInputs(frameCounts: [960_000, 160_000])
    #expect(throws: SpeechError.missingAudio) { try SpeechInputSet([inputs[1]], anchor: 0) }
    #expect(throws: SpeechError.self) { try SpeechInputSet([inputs[0], inputs[0]], anchor: 0) }
}

@Test func preparedAudioEvictionAndCancelledProducerAlwaysAllowOriginalFallback() throws {
    let input = try SpeechInputSet(planningInputs(frameCounts: [320_000]), anchor: 0)
    let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
    let windows = try (0..<3).map { index in
        let range = try FrameRange(start: Int64(index) * 16_000, count: 16_000)
        return try planner.makeWindow(core: range, context: range, input: input)
    }
    let cache = PreparedAudioCache(), owner = UUID(), token = SpeechAttempt()
    for window in windows { try cache.put(owner: owner, window: window, samples: [Float](repeating: 0.1, count: 16_000), attempt: token) }
    #expect(cache.take(windows[0]) == nil)
    #expect(cache.take(windows[1])?.count == 16_000)
    token.cancel()
    #expect(throws: SpeechError.cancelled) { try cache.put(owner: owner, window: windows[0], samples: [], attempt: token) }
    cache.discard(owner: owner)
    #expect(cache.take(windows[2]) == nil)
}

@Test func processingRangeStopsInsideAPhysicalFileWithoutOverlappingTheNextRange() throws {
    let inputs = try planningInputs(frameCounts: [960_000, 160_000])
    let first = try SpeechInputSet(inputs, anchor: 0, through: 400_137)
    let second = try SpeechInputSet(inputs, anchor: 400_137)
    let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "f", count: 64))
    let before = try planner.windows(ranges: [0..<first.modelFrameCount], input: first,
        availableThrough: first.modelFrameCount, tailClosed: true)
    let after = try planner.windows(ranges: [0..<second.modelFrameCount], input: second,
        availableThrough: second.modelFrameCount, tailClosed: true)
    #expect(before.last?.coreFrames.end == 400_137)
    #expect(after.first?.coreFrames.start == 400_137)
    #expect(before.allSatisfy { $0.coreFrames.end <= 400_137 })
    #expect(after.allSatisfy { $0.coreFrames.start >= 400_137 })
    #expect(throws: SpeechError.incompatibleCheckpoint) { try SpeechInputSet(inputs, anchor: 400_137, through: 400_137) }
    #expect(throws: SpeechError.incompatibleCheckpoint) { try SpeechInputSet(inputs, anchor: 0, through: 2_000_000) }
}

@Test(arguments: [44_100, 48_000])
func resamplingIsContinuousAcrossFiles(sampleRate: Int) throws {
    let count = sampleRate * 2 + 137
    let signal = (0..<count).map { Int16((sin(Double($0) * 0.071) * 12_000).rounded()) }
    func read(_ inputs: [SpeechAudioInput]) throws -> [Float] {
        let reader = try EpochAudioReader(input: SpeechInputSet(inputs, anchor: 0), attempt: SpeechAttempt())
        var pcm: [Float] = []
        while let block = try reader.next() { pcm += block }
        return pcm
    }
    let whole = try read(writePCM(signal, sampleRate: sampleRate, fileFrames: count))
    let divided = try read(writePCM(signal, sampleRate: sampleRate, fileFrames: sampleRate + 7))
    #expect(whole.count == Int(Double(count) * 16_000 / Double(sampleRate)))
    #expect(whole == divided)
}

@Test(arguments: [16_000, 44_100, 48_000])
func processingRangeDoesNotReadPastItsSourceBoundary(sampleRate: Int) throws {
    let inputs = try writePCM([Int16](repeating: 0, count: sampleRate * 2), sampleRate: sampleRate, fileFrames: sampleRate * 2)
    let cut: Int64 = Int64(sampleRate + 137)
    let input = try SpeechInputSet(inputs, anchor: 0, through: cut)
    let attempt = SpeechAttempt()
    let recorder = SpeechDiagnosticRecorder(operation: .prepare, attemptID: attempt.id, windowID: nil, fingerprint: "range")
    let reader = try EpochAudioReader(input: input, attempt: attempt, recorder: recorder)
    var frames = 0
    while let block = try reader.next() { frames += block.count }
    #expect(frames == Int(input.modelFrameCount))
    #expect(recorder.value.sourceFramesRead <= cut)
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct RealSpeechTests {
    @Test func shorterBoundaryNeedsLeasedContextDespiteWarmDetector() async throws {
        let directory = testOutput().appendingPathComponent("vad-short-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try writePCM([Int16](repeating: 0, count: 32_000), sampleRate: 16_000,
            fileFrames: 8_000, directory: directory)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelDirectory()), configuration: SpeechConfiguration())
        let first = try await collectAnalysis(engine.prepareStream(inputs: inputs, boundary: .processingRange(16_001)))
        let checkpoint = try #require(first.checkpoint)
        let tail = inputs.filter { $0.envelope.manifest.frames.end > checkpoint.sourceFrame }
        // The detector read to 16,384, but this smaller processing range ends before that.
        await #expect(throws: SpeechError.incompatibleCheckpoint) {
            try await collectAnalysis(engine.prepareStream(inputs: tail, resume: checkpoint, boundary: .processingRange(16_200)))
        }
        let resumed = try await collectAnalysis(engine.prepareStream(inputs: inputs, resume: checkpoint,
            boundary: .processingRange(16_200), replayOrigin: 0))
        #expect(resumed.checkpoint?.sourceFrame == 16_200)
        #expect(try FrameRange.union(first.analyzedCoverage + resumed.analyzedCoverage)
            == [FrameRange(start: 0, count: 16_200)])
    }

    @Test(arguments: [1, 3])
    func archiveBridgesShortPausesAndPreservesOriginalSamples(pauseSeconds: Int) async throws {
        let model = try modelDirectory(), voice = try continuousVoice(model)
        let directory = testOutput().appendingPathComponent("archive-pauses-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gapStart = 16_000 + voice.count
        let samples = [Int16](repeating: 0, count: 16_000) + voice
            + [Int16](repeating: 0, count: pauseSeconds * 16_000) + voice
            + [Int16](repeating: 0, count: 48_000)
        let inputs = try writePCM(samples, sampleRate: 16_000, fileFrames: gapStart + 8_000, directory: directory)
        let configuration = try SpeechConfiguration()
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: configuration)
        let result = try await collectAnalysis(engine.prepareStream(inputs: inputs,
            boundary: .receivedSnapshot(Int64(samples.count))))
        #expect(result.windows.count == (pauseSeconds == 1 ? 1 : 2))
        if pauseSeconds == 1 {
            let window = try #require(result.windows.first)
            try #require(window.coreFrames.start < gapStart)
            try #require(window.coreFrames.end > gapStart + 16_000)
            let reader = try SequentialSpeechSamples(input: SpeechInputSet(inputs, anchor: 0),
                configuration: configuration, attempt: SpeechAttempt())
            let pcm = try reader.samples(for: window.modelContextFrames, sourceContext: window.contextFrames,
                attempt: SpeechAttempt())
            let original = samples[Int(window.contextFrames.start)..<Int(window.contextFrames.end)]
            #expect(pcm.count == original.count)
            #expect(zip(pcm, original).allSatisfy { abs($0.0 - Float($0.1) / 32_768) < 0.0001 })
            let offset = gapStart - Int(window.contextFrames.start)
            #expect(pcm[offset..<(offset + 16_000)].allSatisfy { $0 == 0 })
        } else {
            #expect(result.noSpeechCoverage.contains {
                $0.start <= gapStart + 16_000 && $0.end >= gapStart + 32_000
            })
        }
    }

    @Test func archiveMinuteDoesNotBecomeOneWindowPerBreath() async throws {
        let model = try modelDirectory(), voice = try continuousVoice(model)
        let directory = testOutput().appendingPathComponent("archive-minute-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples = [Int16](repeating: 0, count: 16_000)
        for _ in 0..<15 { samples += voice + [Int16](repeating: 0, count: 16_000) }
        samples += [Int16](repeating: 0, count: 48_000)
        let inputs = try writePCM(samples, sampleRate: 16_000, fileFrames: 10 * 16_000, directory: directory)
        let bundle = try SpeechModelBundle.load(from: model)
        let archive = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let boundary = AudioProcessingBoundary.receivedSnapshot(Int64(samples.count))
        let merged = try await collectAnalysis(archive.prepareStream(inputs: inputs, boundary: boundary))
        print("Archive minute with 15 breaths: \(merged.windows.count) windows")
        #expect(!merged.windows.isEmpty)
        #expect(merged.windows.count <= 4)
        #expect(merged.windows.allSatisfy { $0.modelCoreFrames.count <= 320_000 })
        #expect(try FrameRange.union(merged.windows.map(\.coreFrames)).count == 1)
        #expect(try FrameRange.union(merged.analyzedCoverage) == [FrameRange(start: 0, count: Int64(samples.count))])
    }

    @Test(arguments: ["batch", "restart", "cancel"])
    func batchAndRestartKeepTheContinuousDetectionRanges(mode: String) async throws {
        let restart = mode == "restart"
        let model = try modelDirectory(), voice = try chinesePCM(model)
        let directory = testOutput().appendingPathComponent("vad-continuity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples = [Int16](repeating: 0, count: 210 * 16_000)
        for (second, gain) in [(2, 1.0), (40, 0.12), (117, 0.4), (165, 0.09), (190, 0.3)] {
            for (index, value) in voice.enumerated() {
                samples[second * 16_000 + index] = Int16(Double(value) * gain)
            }
        }
        let inputs = try writePCM(samples, sampleRate: 16_000, fileFrames: 60 * 16_000, directory: directory)
        let bundle = try SpeechModelBundle.load(from: model)
        let full = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let expected = try await collectAnalysis(full.prepareStream(inputs: inputs, boundary: .receivedSnapshot(Int64(samples.count))))
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        func makeEngine() throws -> SpeechEngine {
            try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
                onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
        }
        let engine = try makeEngine()
        let first = try await collectAnalysis(engine.prepareStream(inputs: Array(inputs.prefix(2)),
            boundary: .open, readAheadAllowed: false), cancelAfter: mode == "cancel" ? 110 * 16_000 : nil)
        let checkpoint = try #require(first.checkpoint)
        #expect(checkpoint.sourceFrame < 120 * 16_000)
        let resumedEngine = try restart ? makeEngine() : engine
        let origin = max(0, checkpoint.sourceFrame - 60 * 16_000) / 512 * 512
        let contextInputs = inputs.filter { $0.envelope.manifest.frames.end > origin }
        let second = try await collectAnalysis(resumedEngine.prepareStream(inputs: contextInputs,
            resume: checkpoint, boundary: .receivedSnapshot(Int64(samples.count)), replayOrigin: origin))
        let expectedRanges = try FrameRange.union(expected.windows.map(\.coreFrames))
        let actualRanges = try FrameRange.union((first.windows + second.windows).map(\.coreFrames))
        #expect(actualRanges == expectedRanges, "Scheduling boundaries must not change the detected speech.")
        #expect(try FrameRange.union(first.analyzedCoverage + second.analyzedCoverage)
            == [FrameRange(start: 0, count: Int64(samples.count))])
        let last = try #require(observations.withLock { $0.last })
        if restart {
            #expect((last.vadReplayModelFrames ?? 0) > 0)
            #expect((last.vadReplayModelFrames ?? 0) <= 60 * 16_000 + 512)
            let changed = contextInputs[0].audioURL
            try Data([0]).write(to: changed)
            let cold = try makeEngine()
            await #expect(throws: SpeechError.invalidAudio("audio_identity")) {
                try await collectAnalysis(cold.prepareStream(inputs: contextInputs, resume: checkpoint,
                    boundary: .receivedSnapshot(Int64(samples.count)), replayOrigin: origin))
            }
        } else {
            #expect(last.vadContinuationReused == true)
            #expect((last.vadReplayModelFrames ?? 0) == 0)
            #expect(observations.withLock { $0.reduce(0) { $0 + $1.vadModelFrames } }
                <= Int64(samples.count) + 512)
        }
    }

    @Test func nonFiniteSamplesAreRejectedBeforeNativeVAD() throws {
        let detector = try SherpaVAD(model: modelDirectory().appendingPathComponent("silero_vad.onnx"),
            configuration: SpeechConfiguration())
        for invalid in [Float.nan, Float.infinity, -Float.infinity] {
            var samples = [Float](repeating: 0, count: 512)
            samples[256] = invalid
            #expect(throws: SpeechError.invalidAudio("non_finite_sample")) { try detector.accept(samples) }
        }
        try detector.accept([Float](repeating: 0, count: 512))
        #expect(!detector.speechDetected)
        #expect(try detector.drain().isEmpty)
    }

    @Test func nativeClockRolloverKeepsAbsoluteSpeechCoordinates() throws {
        let model = try modelDirectory(), voice = try chinesePCM(model)
        let directory = testOutput().appendingPathComponent("vad-clock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples = [Int16](repeating: 0, count: 210 * 16_000)
        for second in [2, 117, 177, 200] {
            samples.replaceSubrange((second * 16_000)..<(second * 16_000 + voice.count), with: voice)
        }
        let inputs = try writePCM(samples, sampleRate: 16_000, fileFrames: 960_000, directory: directory)
        let input = try SpeechInputSet(inputs, anchor: 0)
        func detect(limit: Int64) throws -> VADContinuation {
            let context = VADContinuation(input: input, origin: 0, threshold: 0.5,
                detector: try SherpaVAD(model: model.appendingPathComponent("silero_vad.onnx"),
                    configuration: SpeechConfiguration()), nativeFrameLimit: limit)
            let reader = try EpochAudioReader(input: input, attempt: SpeechAttempt())
            var frame: Int64 = 0
            while let block = try reader.next() {
                try context.append(block, at: frame); frame += Int64(block.count)
                while try context.step(through: frame) {}
            }
            try context.finish()
            return context
        }
        let continuous = try detect(limit: 24 * 3_600 * 16_000)
        let rolling = try detect(limit: 120 * 16_000)
        #expect(rolling.rolloverReplayFrames == 2 * 60 * 16_000)
        #expect(rolling.processed == ((Int64(samples.count) + 511) / 512) * 512)
        #expect(rolling.ranges.count == continuous.ranges.count,
            "rolling: \(rolling.ranges); continuous: \(continuous.ranges)")
        // Warm replay can shift the end decision by one 32ms model frame. The
        // planned audio must still contain every reference speech range.
        let planner = WindowPlanner(configuration: try SpeechConfiguration(), fingerprint: String(repeating: "a", count: 64))
        let windows = try planner.windows(ranges: rolling.ranges, input: input,
            availableThrough: Int64(samples.count), tailClosed: true)
        for (actual, expected) in zip(rolling.ranges, continuous.ranges) {
            #expect(abs(actual.lowerBound - expected.lowerBound) <= 512)
            #expect(abs(actual.upperBound - expected.upperBound) <= 512)
            #expect(windows.contains { $0.modelContextFrames.start <= expected.lowerBound && $0.modelContextFrames.end >= expected.upperBound })
        }

    }

    @Test func separatedProcessingRangesAdvanceTheDetectorWithoutReplayingTheWholeEpoch() async throws {
        let model = try modelDirectory(), voice = try chinesePCM(model)
        let directory = testOutput().appendingPathComponent("vad-ranges-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let samples = [Int16](repeating: 0, count: 16_000 * 117) + voice
            + [Int16](repeating: 0, count: 16_000 * 10) + voice
        let inputs = try writePCM(samples, sampleRate: 16_000, fileFrames: 960_000, directory: directory)
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } }, onEvent: { _ in })
        let cut: Int64 = 119 * 16_000 + 137
        let first = try await collectAnalysis(engine.prepareStream(inputs: Array(inputs.prefix(2)), boundary: .processingRange(cut)))
        #expect(first.checkpoint?.sourceFrame == cut)
        let nextStart = cut + 8 * 16_000 + 29
        let resume = SpeechCheckpoint(sessionID: inputs[0].envelope.manifest.sessionID,
            epochID: inputs[0].envelope.manifest.epochID, sourceFrame: nextStart,
            configurationFingerprint: engine.configurationFingerprint)
        let next = try await collectAnalysis(engine.prepareStream(inputs: inputs, resume: resume,
            boundary: .receivedSnapshot(Int64(samples.count))))
        #expect(!next.windows.isEmpty)
        #expect(next.windows.allSatisfy { $0.coreFrames.start >= nextStart })
        #expect(next.checkpoint?.sourceFrame == Int64(samples.count))
        #expect(diagnostics.withLock { $0.last?.vadContinuationReused } == true)
        #expect(diagnostics.withLock { $0.last?.vadReplayModelFrames ?? 0 } < 9 * 16_000)
        #expect(diagnostics.withLock { $0.reduce(Int64(0)) { $0 + $1.vadModelFrames } }
            == ((Int64(samples.count) + 511) / 512) * 512)
    }

    @Test(arguments: [44_100, 48_000])
    func resumedDetectionPreservesTheResamplerPhase(sampleRate: Int) async throws {
        let model = try modelDirectory(), voice = try chinesePCM(model)
        let directory = testOutput().appendingPathComponent("vad-resampling-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var base = [Int16](repeating: 0, count: 40 * 16_000)
        for second in [2, 19, 30] {
            base.replaceSubrange((second * 16_000)..<(second * 16_000 + voice.count), with: voice)
        }
        let samples = (0..<(40 * sampleRate)).map { base[$0 * 16_000 / sampleRate] }
        let inputs = try writePCM(samples, sampleRate: sampleRate, fileFrames: 16 * sampleRate, directory: directory)
        let bundle = try SpeechModelBundle.load(from: model)
        let expectedEngine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let expected = try await collectAnalysis(expectedEngine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(Int64(samples.count))))
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let first = try await collectAnalysis(engine.prepareStream(inputs: [inputs[0]], boundary: .open))
        let checkpoint = try #require(first.checkpoint)
        let second = try await collectAnalysis(engine.prepareStream(inputs: inputs, resume: checkpoint, boundary: .receivedSnapshot(Int64(samples.count))))
        let ranges = try FrameRange.union((first.windows + second.windows).map(\.coreFrames))
        let whole = try FrameRange.union(expected.windows.map(\.coreFrames))
        #expect(ranges.count == whole.count)
        for (a, b) in zip(ranges, whole) {
            #expect(abs(a.start - b.start) <= 3 && abs(a.end - b.end) <= 3)
        }
    }

    @Test func thresholdChangeRebuildsVADAtNextBatchAndKeepsRegisteredWindowsReadable() async throws {
        let (bundle, inputs, directory) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), recognitionBackend: .sherpaCoreML,
            onDiagnostics: { value in records.withLock { $0.append(value) } }, onEvent: { _ in })
        let fingerprint = engine.configurationFingerprint
        let baseline = try await engine.prepare(inputs: inputs, epochClosed: true)
        let original = try #require(baseline.windows.first)
        for threshold: Float in [0.25, 0.15, 0.5] {
            try engine.setVoiceActivityThreshold(threshold)
            let updated = try await engine.prepare(inputs: inputs, epochClosed: true)
            #expect(!updated.windows.isEmpty)
            #expect(records.withLock { $0.last?.vadThreshold } == threshold)
            #expect(engine.configurationFingerprint == fingerprint)
        }
        for invalid: Float in [0, 1, .nan, .infinity] {
            #expect(throws: SpeechError.invalidConfiguration) { try engine.setVoiceActivityThreshold(invalid) }
        }
        #expect(engine.voiceActivityThreshold == 0.5)
        let result = try await engine.transcribe(window: original, inputs: inputs)
        #expect(!result.text.isEmpty)
    }

    @Test(arguments: [9.6, 9.7, 9.8, 9.9], [false, true])
    func checkpointDoesNotCommitUndecidedSpeechAsSilence(quietSeconds: Double, closed: Bool) async throws {
        let model = try modelDirectory()
        let directory = testOutput().appendingPathComponent("vad-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = Array(try chinesePCM(model)[8_000..<78_000])
        let samples = [Int16](repeating: 0, count: Int(quietSeconds * 16_000)) + voice + [Int16](repeating: 0, count: 32_000)
        let inputs = try writePCM(samples, sampleRate: 16_000, fileFrames: 960_000, directory: directory)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
                                     recognitionBackend: .sherpaCoreML)
        let end = Int64(samples.count)
        let first = try await engine.prepare(inputs: inputs, boundary: closed ? .receivedSnapshot(end) : .open)
        let checkpoint = try #require(first.checkpoint)
        #expect(checkpoint.sourceFrame > 0 && checkpoint.sourceFrame < end)
        let stream = engine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end))
        var detected: [FrameRange] = []
        do {
            while let page = try await stream.next() { detected += page.batch.windows.map(\.coreFrames) }
            await stream.waitUntilFinished()
        } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
        #expect(!detected.isEmpty)
        let lost = first.noSpeechCoverage.reduce(Int64(0)) { sum, silent in
            sum + detected.reduce(Int64(0)) { $0 + max(0, min(silent.end, $1.end) - max(silent.start, $1.start)) }
        }
        #expect(lost == 0, "A checkpoint must retain the undecided VAD tail for the next pass.")
        let resumed = try await engine.prepare(inputs: inputs, resume: checkpoint, boundary: .receivedSnapshot(end))
        #expect(!resumed.windows.isEmpty)
        #expect(resumed.checkpoint?.sourceFrame == end)
        #expect(try FrameRange.union(first.analyzedCoverage + resumed.analyzedCoverage) == [FrameRange(start: 0, count: end)])
    }

    @Test func checkpointResumePreservesTheChineseSentence() async throws {
        let model = try modelDirectory()
        let directory = testOutput().appendingPathComponent("vad-sentence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let voice = try chinesePCM(model)
        let inputs = try writePCM([Int16](repeating: 0, count: 145_600) + voice + [Int16](repeating: 0, count: 32_000),
            sampleRate: 16_000, fileFrames: 960_000, directory: directory)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration())
        let first = try await engine.prepare(inputs: inputs, epochClosed: false)
        let resumed = try await engine.prepare(inputs: inputs, resume: #require(first.checkpoint), epochClosed: true)
        var text = ""
        for window in first.windows + resumed.windows { text += try await engine.transcribe(window: window, inputs: inputs).text }
        #expect(text == "开放时间早上9点至下午5点。")
    }

    @Test func flushingDuringPendingSilenceDoesNotFailOrResetTheDetector() throws {
        let directory = try modelDirectory()
        let voice = Array(try chinesePCM(directory)[8_000..<78_000]).map { Float($0) / 32_768 }
        let padded = voice + [Float](repeating: 0, count: (512 - voice.count % 512) % 512)
        var flushed = 0
        for quietFrames in [512, 2_048, 4_096, 6_144] {
            let vad = try SherpaVAD(model: directory.appendingPathComponent("silero_vad.onnx"), configuration: SpeechConfiguration())
            for offset in stride(from: 0, to: padded.count, by: 512) {
                try vad.accept(Array(padded[offset..<(offset + 512)]))
                _ = try vad.drain()
            }
            for _ in 0..<(quietFrames / 512) {
                try vad.accept([Float](repeating: 0, count: 512))
                _ = try vad.drain()
            }
            guard vad.speechDetected else { continue }
            vad.flush()
            #expect(!(try vad.drain()).isEmpty)
            flushed += 1
            for _ in 0..<32 {
                try vad.accept([Float](repeating: 0, count: 512))
                #expect(try vad.drain().allSatisfy { $0.upperBound > $0.lowerBound })
            }
            #expect(!vad.speechDetected)
            vad.reset()
            #expect(try vad.drain().isEmpty)
        }
        #expect(flushed > 0)
    }

    @Test func openIncrementalSilenceKeepsAnUncertainTailAndClosedResumeCompletesIt() async throws {
        let inputs = try writePCM([Int16](repeating: 0, count: 24 * 16_000), sampleRate: 16_000, fileFrames: 12 * 16_000)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: modelDirectory()), configuration: SpeechConfiguration())
        let end = try #require(inputs.last).envelope.manifest.frames.end
        let stream = engine.prepareStream(inputs: inputs, boundary: .open)
        var coverage: [FrameRange] = [], checkpoint: SpeechCheckpoint?
        var waiting = false
        do {
            while let page = try await stream.next() {
                coverage += page.batch.analyzedCoverage
                checkpoint = page.batch.checkpoint ?? checkpoint
                if page.isFinal { waiting = page.batch.waitingForMoreAudio; break }
            }
            await stream.waitUntilFinished()
        } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
        #expect(waiting)
        let resume = try #require(checkpoint)
        #expect(resume.sourceFrame > 0 && resume.sourceFrame < end)
        let remainder = try await engine.prepare(inputs: inputs, resume: resume, boundary: .receivedSnapshot(end))
        #expect(try FrameRange.union(coverage + remainder.analyzedCoverage) == [FrameRange(start: 0, count: end)])
    }

    @Test func incrementalWindowIsRecognizedBeforeAnalysisFinishesAndReusesPCM() async throws {
        let (bundle, inputs, directory) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
            onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
        let end = try #require(inputs.last).envelope.manifest.frames.end
        let stream = engine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end), readAheadAllowed: false)
        do {
            let first = try #require(await stream.next())
            #expect(!first.isFinal)
            let window = try #require(first.batch.windows.first)
            let recognized = try await engine.transcribe(window: window, inputs: inputs)
            #expect(recognized.text == "开放时间早上9点至下午5点。")
            let beforeFinal = observations.withLock { $0 }
            #expect(!beforeFinal.contains { $0.operation == .prepare })
            let recognition = try #require(beforeFinal.first { $0.operation == .transcribe })
            #expect(recognition.preparedAudioModelFrames == window.modelContextFrames.count)
            #expect(recognition.convertedModelFrames == 0 && recognition.sourceFramesRead == 0)
            #expect(recognition.audioHashedBytes > 0)
            var windows = first.batch.windows
            var coverage = first.batch.analyzedCoverage
            while let page = try await stream.next() {
                windows += page.batch.windows
                coverage += page.batch.analyzedCoverage
                if page.isFinal { break }
            }
            await stream.waitUntilFinished()
            #expect(Set(windows.map(\.id)).count == windows.count)
            #expect(try FrameRange.union(coverage) == [FrameRange(start: 0, count: end)])
            let fresh = try await engine.transcribe(window: window, inputs: inputs)
            #expect(fresh == recognized)
            try WireJSON.encode(observations.withLock { $0 }).write(to: testOutput().appendingPathComponent("incremental-pcm-diagnostics.json"))
        } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
    }

    @Test func cachedAnalysisNeverBypassesChangedOriginalAudio() async throws {
        let (bundle, inputs, directory) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let end = try #require(inputs.last).envelope.manifest.frames.end
        let stream = engine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end), readAheadAllowed: false)
        do {
            let page = try #require(await stream.next())
            let window = try #require(page.batch.windows.first)
            let url = try #require(inputs.first).audioURL
            var changed = try Data(contentsOf: url)
            changed[changed.count - 100] ^= 0xff
            try changed.write(to: url, options: .atomic)
            await #expect(throws: SpeechError.invalidAudio("audio_identity")) {
                try await engine.transcribe(window: window, inputs: inputs)
            }
            stream.cancel(); await stream.waitUntilFinished()
        } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
    }

    @Test func incrementalSnapshotContinuesPastOldCheckpointsWithOneConversion() async throws {
        let model = try modelDirectory(), voice = try chinesePCM(model)
        let source = Array(repeating: voice, count: 16).flatMap { $0 } + [Int16](repeating: 0, count: 32_000)
        let directory = testOutput().appendingPathComponent("speech-long-stream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try writePCM(source, sampleRate: 16_000, fileFrames: 320_000, directory: directory)
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: model), configuration: SpeechConfiguration(),
            onDiagnostics: { value in observations.withLock { $0.append(value) } }, onEvent: { _ in })
        let end = try #require(inputs.last).envelope.manifest.frames.end
        #expect(end > 64 * 16_000)
        let stream = engine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end))
        var windows: [SpeechWindow] = [], coverage: [FrameRange] = []
        do {
            while let page = try await stream.next() {
                windows += page.batch.windows; coverage += page.batch.analyzedCoverage
                if page.isFinal { break }
            }
            await stream.waitUntilFinished()
        } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
        #expect(windows.contains { $0.coreFrames.end > 64 * 16_000 })
        #expect(Set(windows.map(\.id)).count == windows.count)
        for pair in zip(windows, windows.dropFirst()) { #expect(pair.0.coreFrames.end <= pair.1.coreFrames.start) }
        #expect(try FrameRange.union(coverage) == [FrameRange(start: 0, count: end)])
        let prepare = try #require(observations.withLock { $0.first })
        #expect(prepare.convertedModelFrames == end)
        #expect(prepare.sourceFramesRead == end)
        #expect(prepare.outputWindowCount == windows.count)
    }

    @Test func independentProcessingRangesPreserveAudioCoverageAndRecognizeAcrossTheBoundary() async throws {
        let (bundle, inputs, _) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        let end = try #require(inputs.last).envelope.manifest.frames.end
        let cut = end / 2
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let first = try await engine.prepare(inputs: inputs, boundary: .processingRange(cut))
        let second = try await engine.prepare(inputs: inputs, resume: #require(first.checkpoint), boundary: .receivedSnapshot(end))
        #expect(first.checkpoint?.sourceFrame == cut)
        #expect(second.checkpoint?.sourceFrame == end)
        #expect(first.windows.allSatisfy { $0.coreFrames.end <= cut })
        #expect(second.windows.allSatisfy { $0.coreFrames.start >= cut })
        #expect(try FrameRange.union(first.analyzedCoverage + second.analyzedCoverage) == [FrameRange(start: 0, count: end)])
        var text = ""
        for window in first.windows + second.windows {
            let result = try await engine.transcribe(window: window, inputs: inputs)
            text += result.text
        }
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func analysisReusesVADWithoutLoadingASRAndRunsBesideRecognition() async throws {
        let (bundle, inputs, _) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let entered = DispatchSemaphore(value: 0), analyzed = DispatchSemaphore(value: 0)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), onDiagnostics: { value in
            diagnostics.withLock { $0.append(value) }
        }, onEvent: { event in
            if case .nativeDecodeStarted = event {
                entered.signal()
                if analyzed.wait(timeout: .now() + 10) != .success { timedOut.withLock { $0 = true } }
            }
        })
        let first = try await engine.prepare(inputs: inputs, epochClosed: true)
        #expect(diagnostics.withLock { $0.count == 1 && $0[0].modelLoadSeconds == 0 && $0[0].vadLoadSeconds > 0 })
        let recognition = Task { try await engine.transcribe(window: #require(first.windows.first), inputs: inputs) }
        defer { analyzed.signal() }
        let started = await Task.detached { waitForSpeechEntry(entered) }.value
        #expect(started)
        let silent = try writePCM([Int16](repeating: 0, count: 32_000), sampleRate: 16_000, fileFrames: 32_000)
        let quiet = try await engine.prepare(inputs: silent, epochClosed: true)
        analyzed.signal()
        let result = try await recognition.value
        #expect(!timedOut.withLock { $0 })
        #expect(quiet.windows.isEmpty && quiet.noSpeechCoverage == quiet.analyzedCoverage)
        #expect(result.text == "开放时间早上9点至下午5点。")
        let repeated = try await engine.prepare(inputs: inputs, epochClosed: true)
        #expect(repeated.windows == first.windows)
        #expect(repeated.checkpoint == first.checkpoint)
        #expect(repeated.analyzedCoverage == first.analyzedCoverage)
        let values = diagnostics.withLock { $0 }
        #expect(values.filter { $0.vadLoadSeconds > 0 }.count == 1)
        #expect(values.filter { $0.modelLoadSeconds > 0 }.count == 1)
        #expect(values.filter { $0.operation == .prepare && $0.modelHashedBytes > 0 }.count == 1)
        #expect(values.filter { $0.operation == .transcribe && $0.modelHashedBytes > 0 }.count == 1)
    }

    @Test func closedResampledEpochConsumesFractionalTail() async throws {
        let bundle = try SpeechModelBundle.load(from: modelDirectory())
        let inputs = try writePCM([Int16](repeating: 0, count: 200_003), sampleRate: 44_100, fileFrames: 100_000)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let batch = try await engine.prepare(inputs: inputs, epochClosed: true)
        #expect(batch.checkpoint?.sourceFrame == 200_003)
        #expect(batch.windows.isEmpty)
        #expect(batch.noSpeechCoverage == batch.analyzedCoverage)
    }

    @Test func longContinuousSpeechKeepsAlreadyPublishedCoreIdentities() async throws {
        let directory = try modelDirectory()
        let voice = Array(try chinesePCM(directory)[8_000..<78_000])
        let inputs = try writePCM((0..<10).flatMap { _ in voice }, sampleRate: 16_000, fileFrames: 320_000)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: directory), configuration: SpeechConfiguration())
        let live = try await engine.prepare(inputs: Array(inputs.prefix(2)), epochClosed: false)
        let closed = try await engine.prepare(inputs: inputs, epochClosed: true)
        #expect(!live.windows.isEmpty)
        #expect(live.windows == Array(closed.windows.prefix(live.windows.count)))
        #expect(closed.windows.allSatisfy { $0.modelCoreFrames.count <= 320_000 })
        #expect(zip(closed.windows, closed.windows.dropFirst()).allSatisfy { pair in pair.0.coreFrames.end <= pair.1.coreFrames.start })
    }

    @Test func senseVoiceRecognizesChineseAndPreservesRawTokens() async throws {
        let (bundle, inputs, _) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        let batch = try await engine.prepare(inputs: inputs, epochClosed: true)
        #expect(!batch.windows.isEmpty)
        let result = try await engine.transcribe(window: #require(batch.windows.first), inputs: inputs)
        // Independent oracle: official sherpa pretrained model documentation, zh.wav with ITN enabled.
        #expect(result.text == "开放时间早上9点至下午5点。")
        #expect(!result.tokens.isEmpty)
        #expect(result.timestamps.count == result.tokens.count)
        #expect(result.rawJSON.contains(result.text))
    }

    @Test func continuousBacklogPublishesBoundedCheckpointsWithoutWaitingForCaptureEnd() async throws {
        let directory = try modelDirectory()
        let voice = Array(try chinesePCM(directory)[8_000..<78_000])
        let inputs = try writePCM((0..<40).flatMap { _ in voice }, sampleRate: 16_000, fileFrames: 960_000)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: directory), configuration: SpeechConfiguration())
        let first = try await engine.prepare(inputs: inputs, epochClosed: false)
        let checkpoint = try #require(first.checkpoint)
        #expect(checkpoint.sourceFrame > 0 && checkpoint.sourceFrame <= 1_024_000)
        #expect(first.analyzedCoverage.last?.end == checkpoint.sourceFrame)
        #expect(!first.waitingForMoreAudio)
        #expect(!first.windows.isEmpty)
        let second = try await engine.prepare(inputs: inputs, resume: checkpoint, epochClosed: false)
        #expect(try #require(second.checkpoint).sourceFrame > checkpoint.sourceFrame)
        #expect(second.windows.allSatisfy { $0.coreFrames.start >= checkpoint.sourceFrame })
    }

    @Test func forcedFlushFollowedByLongSilenceStillAdvancesOpenCheckpoint() async throws {
        let directory = try modelDirectory()
        let voice = try continuousVoice(directory)
        // Continuous speech > 16s (256,000 frames) triggers a forced VAD flush, followed by 30s of silence.
        let continuousSpeech = Array(repeating: voice, count: 7).flatMap { $0 }
        let trailingSilence = [Int16](repeating: 0, count: 30 * 16_000)
        let outDir = testOutput().appendingPathComponent("vad-forced-flush-silence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: outDir) }
        let inputs = try writePCM(continuousSpeech + trailingSilence, sampleRate: 16_000, fileFrames: 960_000, directory: outDir)
        let engine = try SpeechEngine(bundle: SpeechModelBundle.load(from: directory), configuration: SpeechConfiguration())
        let batch = try await collectAnalysis(engine.prepareStream(inputs: inputs, boundary: .open))
        let checkpoint = try #require(batch.checkpoint)
        let speechEnd = Int64(continuousSpeech.count)
        let totalEnd = try #require(inputs.last).envelope.manifest.frames.end
        // Checkpoint must advance well past speechEnd into the trailing silence (leaving only the ~10s pending tail).
        #expect(checkpoint.sourceFrame > speechEnd + 15 * 16_000)
        #expect(checkpoint.sourceFrame <= totalEnd)
        #expect(!batch.windows.isEmpty)
    }

    @Test func speechCrossesSixtySecondFileWithoutPrematureTailCommit() async throws {
        let (bundle, inputs, _) = try fixture(silenceBefore: 57, fileFrames: 960_000)
        #expect(inputs.count == 2)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration())
        var resume: SpeechCheckpoint?
        while true {
            let batch = try await engine.prepare(inputs: [inputs[0]], resume: resume, epochClosed: false)
            #expect(batch.windows.isEmpty)
            if batch.waitingForMoreAudio { break }
            resume = try #require(batch.checkpoint)
        }
        let continued = try await engine.prepare(inputs: inputs, resume: resume, epochClosed: true)
        let window = try #require(continued.windows.first)
        #expect(window.coreFrames.start < 960_000)
        #expect(window.coreFrames.end > 960_000)
        #expect(window.sources.count == 2)
        let repeated = try await engine.prepare(inputs: inputs, resume: resume, epochClosed: true)
        #expect(continued.windows == repeated.windows)
        #expect(continued.checkpoint == repeated.checkpoint)
        let result = try await engine.transcribe(window: window, inputs: inputs)
        #expect(result.text.contains("时间"))
    }

    @Test func nativeCancellationDiscardsResultThenExecutorRemainsUsable() async throws {
        let (bundle, inputs, _) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        let attempt = SpeechAttempt()
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration()) { event in
            if case .nativeDecodeStarted = event { attempt.cancel() }
        }
        let batch = try await engine.prepare(inputs: inputs, epochClosed: true)
        let window = try #require(batch.windows.first)
        await #expect(throws: SpeechError.cancelled) {
            try await engine.transcribe(window: window, inputs: inputs, attempt: attempt)
        }
        // The callback cancels only the old ticket. A fresh attempt still uses the same recognizer safely.
        let result = try await engine.transcribe(window: window, inputs: inputs)
        #expect(!result.text.isEmpty)
    }

    @Test func changedModelHashBlocksNativeLoad() throws {
        let directory = try modelDirectory()
        let original = try SpeechModelBundle.load(from: directory)
        let changed = try SpeechModelManifest(asrSHA256: String(repeating: "0", count: 64),
                                              tokensSHA256: original.manifest.tokensSHA256,
                                              vadSHA256: original.manifest.vadSHA256)
        #expect(throws: SpeechError.modelHashMismatch("model.int8.onnx")) {
            try SpeechModelBundle(directory: directory, manifest: changed).validate()
        }
    }
}

private func collectAnalysis(_ stream: SpeechAnalysisStream, cancelAfter: Int64? = nil) async throws -> SpeechAnalysisBatch {
    var windows: [SpeechWindow] = [], coverage: [FrameRange] = [], silence: [FrameRange] = []
    var checkpoint: SpeechCheckpoint?
    var waiting = false
    do {
        while let page = try await stream.next() {
            windows += page.batch.windows
            coverage += page.batch.analyzedCoverage
            silence += page.batch.noSpeechCoverage
            checkpoint = page.batch.checkpoint ?? checkpoint
            waiting = page.batch.waitingForMoreAudio
            if let cancelAfter, (checkpoint?.sourceFrame ?? 0) >= cancelAfter {
                #expect(!page.isFinal)
                stream.cancel()
                break
            }
        }
        await stream.waitUntilFinished()
        return SpeechAnalysisBatch(windows: windows, analyzedCoverage: coverage, noSpeechCoverage: silence,
            checkpoint: checkpoint, waitingForMoreAudio: waiting)
    } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
}

private func waitForSpeechEntry(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"] != nil))
struct RealCoreMLSpeechTests {
    // The pinned Silero v6 bundle keeps the reference utterance intact.
    private let wholeClipModelOutput = "开放时间早上9点至下午5点。"
    @Test func dictationCompletesWhileArchiveAnalysisWaitsForItsConsumer() async throws {
        let (bundle, inputs, directory) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
            recognitionBackend: .sherpaCoreML,
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } }, onEvent: { _ in })
        try await engine.warmUp()
        let end = try #require(inputs.last).envelope.manifest.frames.end
        let stream = engine.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end), readAheadAllowed: false)
        // A failed implementation must fail the test instead of leaving its producer blocked forever.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            stream.cancel()
        }
        do {
            let page = try #require(await stream.next())
            #expect(!page.isFinal)
            let samples = try chinesePCM(bundle.directory).map { Float($0) / 32_768 }
            let text = try await engine.dictate(samples: samples)
            #expect(text == wholeClipModelOutput)
            #expect(!diagnostics.withLock { $0.contains { $0.operation == .prepare } },
                    "Microphone recognition must finish before archive analysis is released.")
            stream.cancel()
            await stream.waitUntilFinished()
            watchdog.cancel()
        } catch {
            stream.cancel()
            await stream.waitUntilFinished()
            watchdog.cancel()
            throw error
        }
    }

    @Test func dictationReusesWarmedModelAndRejectsSilenceWithoutArchiveEvents() async throws {
        let bundle = try SpeechModelBundle.load(from: modelDirectory())
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let events = OSAllocatedUnfairLock(initialState: 0)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
            recognitionBackend: .sherpaCoreML,
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } },
            onEvent: { _ in events.withLock { $0 += 1 } })
        try await engine.warmUp()
        let samples = try chinesePCM(bundle.directory).map { Float($0) / 32_768 }
        let text = try await engine.dictate(samples: samples)
        #expect(text == wholeClipModelOutput)
        #expect(try await engine.dictate(samples: Array(repeating: 0, count: 32_000)) == "")
        let decoded = diagnostics.withLock { $0.filter { $0.operation == .dictate } }
        #expect(!decoded.isEmpty)
        #expect(decoded.allSatisfy { $0.modelLoadSeconds == 0 && $0.modelHashedBytes == 0 })
        #expect(events.withLock { $0 } == 0)
    }

    @Test func languageSwitchKeepsInflightChoiceAndReusesLoadedModels() async throws {
        let bundle = try SpeechModelBundle.load(from: modelDirectory())
        let directory = testOutput().appendingPathComponent("language-switch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try writePCM(chinesePCM(bundle.directory), sampleRate: 16_000,
                                  fileFrames: 960_000, directory: directory)
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engineBox = OSAllocatedUnfairLock<SpeechEngine?>(initialState: nil)
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
            recognitionBackend: .sherpaCoreML,
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } },
            onEvent: { event in
                if case .nativeDecodeStarted = event {
                    do { try engineBox.withLock { $0 }?.setRecognitionLanguage(.korean) }
                    catch { Issue.record(error) }
                }
            })
        engineBox.withLock { $0 = engine }
        defer { engineBox.withLock { $0 = nil } }
        let batch = try await engine.prepare(inputs: inputs, epochClosed: true)
        let window = try #require(batch.windows.first)
        let fingerprint = engine.configurationFingerprint
        try engine.setRecognitionLanguage(.mandarin)
        let first = try await engine.transcribe(window: window, inputs: inputs)
        #expect(first.text == wholeClipModelOutput)
        #expect(first.recognitionFingerprint != nil)
        #expect(engine.recognitionLanguage == .korean)
        let next = try await engine.transcribe(window: window, inputs: inputs)
        #expect(next.recognitionFingerprint != first.recognitionFingerprint)
        try engine.setRecognitionLanguage(.mandarin)
        let sequence = try engine.makeTranscriptionSequence(inputs: inputs, anchor: window.analysisAnchor)
        let restored: SpeechRecognition
        do {
            restored = try await engine.transcribe(window: window, sequence: sequence)
        } catch {
            await engine.close(sequence)
            throw error
        }
        await engine.close(sequence)
        #expect(restored.text == first.text)
        #expect(restored.recognitionFingerprint == first.recognitionFingerprint)
        #expect(engine.configurationFingerprint == fingerprint)
        let decodes = diagnostics.withLock { $0.filter { $0.operation == .transcribe } }
        #expect(decodes.count == 3)
        #expect(decodes.allSatisfy { $0.modelLoadSeconds > 0 })
    }

    @Test func coreMLWarmupReusesOneRuntimeAndLeavesAnalysisAvailable() async throws {
        let (bundle, inputs, directory) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let engine = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), recognitionBackend: .sherpaCoreML,
            coreMLCacheDirectory: testOutput().appendingPathComponent("model-cache-real"),
            onDiagnostics: { value in diagnostics.withLock { $0.append(value) } }, onEvent: { _ in })
        async let first: Void = engine.warmUp()
        async let second: Void = engine.warmUp()
        let batch = try await engine.prepare(inputs: inputs, epochClosed: true)
        _ = try await (first, second)
        let prepared = diagnostics.withLock { $0.filter { $0.operation == .warmUp } }
        #expect(prepared.count == 2)
        #expect(prepared.filter { $0.modelLoadSeconds > 0 }.count == 1)
        #expect(prepared.filter { $0.nativeDecodeSeconds > 0 }.count == 1)
        #expect(prepared.allSatisfy { $0.outcome == .completed })
        let result = try await engine.transcribe(window: #require(batch.windows.first), inputs: inputs)
        #expect(result.text == "开放时间早上9点至下午5点。")
        let last = try #require(diagnostics.withLock { $0.last })
        #expect(last.operation == .transcribe && last.modelLoadSeconds == 0 && last.modelHashedBytes == 0)
    }

    @Test func coreMLRecognizesExistingWindowsReusesPCMAndDiscardsLateCancelledResults() async throws {
        let (bundle, inputs, directory) = try fixture(silenceBefore: 0, fileFrames: 960_000)
        defer { try? FileManager.default.removeItem(at: directory) }
        let observations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let cancelOnReturn = OSAllocatedUnfairLock<SpeechAttempt?>(initialState: nil)
        let referenceObservations = OSAllocatedUnfairLock(initialState: [SpeechDiagnostics]())
        let coreML = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(), recognitionBackend: .sherpaCoreML,
            onDiagnostics: { diagnostic in observations.withLock { $0.append(diagnostic) } }, onEvent: { event in
                if case .nativeDecodeReturned = event { cancelOnReturn.withLock { $0?.cancel() } }
            })
        let reference = try SpeechEngine(bundle: bundle, configuration: SpeechConfiguration(),
            onDiagnostics: { diagnostic in referenceObservations.withLock { $0.append(diagnostic) } }, onEvent: { _ in })
        let expectedWindows = try await reference.prepare(inputs: inputs, epochClosed: true).windows
        let end = try #require(inputs.last).envelope.manifest.frames.end
        let stream = coreML.prepareStream(inputs: inputs, boundary: .receivedSnapshot(end), readAheadAllowed: false)
        do {
            let first = try #require(await stream.next())
            let window = try #require(first.batch.windows.first)
            #expect(expectedWindows.contains(window))
            let cold = try await coreML.transcribe(window: window, inputs: inputs)
            #expect(cold.text == "开放时间早上9点至下午5点。")
            #expect(cold.tokens.count == cold.timestamps.count && !cold.tokens.isEmpty)
            #expect(cold.timestamps == cold.timestamps.sorted())
            #expect(cold.timestamps.allSatisfy { $0 >= 0 && Double($0) <= Double(window.modelContextFrames.count) / 16_000 })
            #expect(ContentHash.isValid(try #require(cold.recognitionFingerprint)))
            #expect(!cold.rawJSON.isEmpty)
            let initial = try #require(observations.withLock { $0.first(where: { $0.operation == .transcribe }) })
            #expect(initial.preparedAudioModelFrames == window.modelContextFrames.count)
            #expect(initial.convertedModelFrames == 0 && initial.sourceFramesRead == 0)
            #expect(initial.modelLoadSeconds > 0 && initial.modelHashedBytes > 0)
            var actualWindows = first.batch.windows
            while let page = try await stream.next() {
                actualWindows += page.batch.windows
                if page.isFinal { break }
            }
            await stream.waitUntilFinished()
            #expect(actualWindows == expectedWindows)
            for _ in 0..<3 {
                let warm = try await coreML.transcribe(window: window, inputs: inputs)
                expectCoreMLRepeat(warm, matches: cold)
            }
            let warmDiagnostics = try #require(observations.withLock { $0.last })
            #expect(warmDiagnostics.modelHashedBytes == 0 && warmDiagnostics.modelLoadSeconds == 0)
            let referenceResult = try await reference.transcribe(window: window, inputs: inputs)
            #expect(referenceResult.text == cold.text)
            for _ in 0..<3 {
                let warmReference = try await reference.transcribe(window: window, inputs: inputs)
                #expect(warmReference == referenceResult)
            }
            let attempt = SpeechAttempt()
            cancelOnReturn.withLock { $0 = attempt }
            await #expect(throws: SpeechError.cancelled) {
                try await coreML.transcribe(window: window, inputs: inputs, attempt: attempt)
            }
            cancelOnReturn.withLock { $0 = nil }
            let retried = try await coreML.transcribe(window: window, inputs: inputs)
            expectCoreMLRepeat(retried, matches: cold)
            try WireJSON.encode(["coreml": observations.withLock { $0 }, "sherpa": referenceObservations.withLock { $0 }])
                .write(to: testOutput().appendingPathComponent("coreml-real-model-diagnostics.json"))
        } catch { stream.cancel(); await stream.waitUntilFinished(); throw error }
    }
}

private func expectCoreMLRepeat(_ actual: SpeechRecognition, matches expected: SpeechRecognition) {
    #expect(actual.windowID == expected.windowID && actual.configurationFingerprint == expected.configurationFingerprint)
    #expect(actual.recognitionFingerprint == expected.recognitionFingerprint)
    #expect(actual.text == expected.text && actual.tokens == expected.tokens)
    #expect(actual.timestamps.count == expected.timestamps.count)
    // Core ML's cold specialization can move an equal-probability CTC peak by
    // one 60 ms acoustic frame. Text must remain exact; timing drift is bounded.
    #expect(zip(actual.timestamps, expected.timestamps).allSatisfy { abs($0 - $1) <= 0.0601 })
    #expect(actual.timestamps == actual.timestamps.sorted() && !actual.rawJSON.isEmpty)
    #expect(actual.speakers == expected.speakers && actual.speakerTurns == expected.speakerTurns)
    #expect(actual.speakerFailure == expected.speakerFailure)
}

private func modelDirectory() throws -> URL {
    URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MOMO_SPEECH_MODEL_DIRECTORY"]))
}

private func testOutput() -> URL {
    ProcessInfo.processInfo.environment["MOMO_TEST_OUTPUT_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
}

private func fixture(silenceBefore: Int, fileFrames: Int) throws -> (SpeechModelBundle, [SpeechAudioInput], URL) {
    let model = try modelDirectory()
    let voice = try chinesePCM(model)
    let directory = testOutput().appendingPathComponent("speech-test-" + UUID().uuidString)
    let inputs = try writePCM([Int16](repeating: 0, count: silenceBefore * 16_000) + voice + [Int16](repeating: 0, count: 32_000),
                              sampleRate: 16_000, fileFrames: fileFrames, directory: directory)
    return (try SpeechModelBundle.load(from: model), inputs, directory)
}

private func chinesePCM(_ directory: URL) throws -> [Int16] {
    let audio = try AVAudioFile(forReading: directory.appendingPathComponent("test_wavs/zh.wav"),
                                commonFormat: .pcmFormatFloat32, interleaved: false)
    #expect(audio.processingFormat.sampleRate == 16_000)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
    try audio.read(into: buffer)
    let floats = try #require(buffer.floatChannelData?[0])
    return (0..<Int(buffer.frameLength)).map { Int16(max(-32_768, min(32_767, (floats[$0] * 32_767).rounded()))) }
}

private func continuousVoice(_ directory: URL) throws -> [Int16] {
    let samples = try chinesePCM(directory)
    let detector = try SherpaVAD(model: directory.appendingPathComponent("silero_vad.onnx"),
        configuration: SpeechConfiguration(minimumSilenceSeconds: 0.5))
    for start in stride(from: 0, to: samples.count, by: 512) {
        var frame = samples[start..<min(samples.count, start + 512)].map { Float($0) / 32_768 }
        frame += repeatElement(0, count: 512 - frame.count)
        try detector.accept(frame)
    }
    detector.flush()
    let range = try #require(detector.drain().max { $0.count < $1.count })
    let start = Int(range.lowerBound), end = min(samples.count, Int(range.upperBound), start + 48_000)
    #expect(end - start == 48_000)
    return Array(samples[start..<end])
}

private func writePCM(_ samples: [Int16], sampleRate: Int, fileFrames: Int, directory: URL? = nil) throws -> [SpeechAudioInput] {
    var writer = try PCM16SegmentWriter(directory: directory ?? testOutput().appendingPathComponent(UUID().uuidString),
                                        sessionID: UUID(), epochID: UUID(), sourceDeviceID: UUID(),
                                        sourceBuild: "speech-e2e", sourceKind: .fixture, sampleRate: sampleRate, targetFrames: fileFrames,
                                        wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 28_800)
    var chunks = try writer.append(samples)
    if let tail = try writer.finish() { chunks.append(tail) }
    return chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
}

private func planningInputs(frameCounts: [Int64]) throws -> [SpeechAudioInput] {
    let session = UUID(), epoch = UUID(), device = UUID()
    var start: Int64 = 0
    return try frameCounts.enumerated().map { index, count in
        let manifest = try ChunkManifest(sessionID: session, epochID: epoch, sourceDeviceID: device, sourceBuild: "unit-test",
                                          sequence: Int64(index), frames: FrameRange(start: start, count: count), timebaseHz: 16_000,
                                          wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 0, codec: .pcmInt16,
                                          sampleRate: 16_000, channels: 1, decodedFrameCount: count, byteCount: count * 2 + 44,
                                          audioSHA256: String(repeating: "a", count: 64), sourceKind: .fixture)
        start += count
        return SpeechAudioInput(envelope: try ManifestEnvelope(manifest: manifest), audioURL: URL(fileURLWithPath: "/unused/\(index).wav"))
    }
}
