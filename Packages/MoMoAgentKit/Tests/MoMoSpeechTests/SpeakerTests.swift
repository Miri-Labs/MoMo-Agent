import Foundation
import SherpaOnnxC
import Testing
import MoMoContracts
import MoMoRecording
@testable import MoMoSpeech

struct SpeakerAlignmentTests {
    @Test func acousticTurnsSplitWithoutTokensAndKeepShortDifferentSpeakers() throws {
        let revision = String(repeating: "a", count: 64)
        func evidence(_ start: Double, _ end: Double, _ track: Int, vector: [Float] = []) -> SpeakerEvidence {
            .init(start: start, end: end, localSpeaker: track, embedding: vector, cleanSeconds: 0, modelRevision: revision)
        }
        let plan = SpeakerTurn.plan([evidence(0.2, 2, 1), evidence(2.3, 4, 1), evidence(4.1, 4.7, 2)], core: 0..<80_000)
        #expect(plan.count == 2)
        #expect(plan[0].frames.lowerBound == 0)
        #expect(plan[0].frames.upperBound == plan[1].frames.lowerBound)
        #expect(plan[1].frames.upperBound == 80_000)
        let timed = SpeechRecognition(windowID: "timed", text: "明天见嗯", tokens: ["明", "天", "见", "嗯"],
            timestamps: [0.5, 1, 3, 4.2], rawJSON: "{}", configurationFingerprint: "test")
        #expect(timed.alignedSpeakerTurns(plan)?.map(\.text) == ["明天见", "嗯"])
        let interjection = SpeechRecognition(windowID: "short", text: "过了嗯，但是", tokens: ["过", "了", "嗯", "，", "但", "是"],
            timestamps: [0.36, 0.48, 0.78, 0.96, 1.2, 1.32], rawJSON: "{}", configurationFingerprint: "test")
        let shortTurns = SpeakerTurn.plan([evidence(0, 0.79, 1), evidence(0.79, 1.14, 2), evidence(1.14, 2, 1)], core: 0..<32_000)
        #expect(interjection.alignedSpeakerTurns(shortTurns)?.map(\.text) == ["过了", "嗯，", "但是"])
        let frames = try FrameRange(start: 32_000, count: 80_000)
        let context = try FrameRange(start: 16_000, count: 112_000)
        let window = SpeechWindow(id: "w", sessionID: UUID(), epochID: UUID(), analysisAnchor: 0,
            coreFrames: frames, contextFrames: context, modelCoreFrames: frames, modelContextFrames: context,
            sources: [], replayInputManifestHashes: [], configurationFingerprint: "test")
        var result = SpeechRecognition(windowID: "w", text: "明天12点见。好。", tokens: [], timestamps: [], rawJSON: "{}", configurationFingerprint: "test")
        result.speakerTurns = [
            .init(text: "明天12点见。", start: 1, end: 5.05, evidence: plan[0].evidence),
            .init(text: "好。", start: 5.05, end: 6, evidence: plan[1].evidence)]
        #expect(result.textOwned(by: window) == result.text)
        let parts = try #require(try result.speakerParts(text: result.text, window: window))
        #expect(parts.map(\.text) == ["明天12点见。", "好。"])
        #expect(parts.first?.frames.start == frames.start)
        #expect(parts.last?.frames.end == frames.end)
        #expect(parts[0].frames.end == parts[1].frames.start)
        // Different tracks in the same block must not collapse even if their vectors look alike.
        let vector: [Float] = [1] + Array(repeating: 0, count: 255)
        #expect(!SpeakerTurn.sameVoice(evidence(0, 2, 1, vector: vector), evidence(2, 4, 2, vector: vector)))
        #expect(SpeakerTurn.sameVoice(evidence(8, 10, 1, vector: vector), evidence(10, 12, 4, vector: vector)))
    }

    @Test func timingSplitsWithoutLosingTextAndDoesNotGuessThroughITN() throws {
        let range = try FrameRange(start: 0, count: 160_000)
        let window = SpeechWindow(id: "w", sessionID: UUID(), epochID: UUID(), analysisAnchor: 0,
            coreFrames: range, contextFrames: range, modelCoreFrames: range, modelContextFrames: range,
            sources: [], replayInputManifestHashes: [], configurationFingerprint: "test")
        var recognition = SpeechRecognition(windowID: "w", text: "你好世界", tokens: ["你", "好", "世", "界"],
            timestamps: [0.5, 2, 5, 7], rawJSON: "{}", configurationFingerprint: "test")
        recognition.speakers = [SpeakerEvidence(start: 0, end: 4, localSpeaker: 1,
            embedding: [1] + Array(repeating: 0, count: 255), cleanSeconds: 4, modelRevision: String(repeating: "a", count: 64)),
            SpeakerEvidence(start: 4, end: 9, localSpeaker: 2,
            embedding: [0, 1] + Array(repeating: 0, count: 254), cleanSeconds: 5, modelRevision: String(repeating: "a", count: 64))]
        let parts = try #require(try recognition.speakerParts(text: recognition.text, window: window))
        #expect(parts.map(\.text) == ["你好", "世界"])
        #expect(parts[0].frames.end == parts[1].frames.start)
        #expect(parts[0].evidence?.localSpeaker == 1)
        #expect(parts[1].evidence?.localSpeaker == 2)
        let transformed = SpeechRecognition(windowID: "w", text: "123", tokens: ["一", "二", "三"],
            timestamps: [1, 2, 3], rawJSON: "{}", configurationFingerprint: "test", speakers: recognition.speakers)
        #expect(try transformed.speakerParts(text: "123", window: window) == nil)
        var single = transformed
        single.speakers = Array(recognition.speakers!.prefix(1))
        #expect(try single.speakerParts(text: "123", window: window)?.first?.evidence?.localSpeaker == 1)
    }

    @Test func collarAndSentenceBoundarySnappingKeepSentencesWholeAcrossTurnJitter() throws {
        let revision = String(repeating: "b", count: 64)
        let v1: [Float] = [1] + Array(repeating: 0, count: 255)
        let v2: [Float] = [0, 1] + Array(repeating: 0, count: 254)
        let core = 16_000..<96_000
        let bounds = 0..<112_000
        let ev1 = SpeakerEvidence(start: 1.15, end: 3.00, localSpeaker: 1, embedding: v1, cleanSeconds: 1.85, modelRevision: revision)
        let ev2 = SpeakerEvidence(start: 3.30, end: 5.80, localSpeaker: 2, embedding: v2, cleanSeconds: 2.50, modelRevision: revision)
        let turns = SpeakerTurn.plan([ev1, ev2], core: core, sampleBounds: bounds)
        #expect(turns.count == 2)
        // Core partition stays exact and contiguous, while audioFrames expands into quiet margins without crossing speech.
        #expect(turns[0].frames.lowerBound == core.lowerBound)
        #expect(turns[0].frames.upperBound == turns[1].frames.lowerBound)
        #expect(turns[1].frames.upperBound == core.upperBound)
        #expect(turns[0].audioFrames.lowerBound < turns[0].frames.lowerBound)
        #expect(turns[0].audioFrames.upperBound <= Int((ev2.start * 16_000).rounded(.down)))
        #expect(turns[1].audioFrames.lowerBound >= Int((ev1.end * 16_000).rounded(.up)))

        // Midpoint is 3.15 s; "见"(3.18s) + "。"(3.24s) jittered slightly past midpoint should snap back to Speaker 1.
        let jittered = SpeechRecognition(
            windowID: "snap",
            text: "明天见。好的没问题。",
            tokens: ["明", "天", "见", "。", "好", "的", "没", "问", "题", "。"],
            timestamps: [1.10, 1.50, 3.18, 3.24, 3.45, 3.65, 4.00, 4.30, 4.60, 5.88],
            rawJSON: "{}",
            configurationFingerprint: "test",
            speakers: [ev1, ev2])
        #expect(jittered.alignedSpeakerTurns(turns)?.map(\.text) == ["明天见。", "好的没问题。"])

        let frameRange = try FrameRange(start: 16_000, count: 80_000)
        let ctxRange = try FrameRange(start: 0, count: 112_000)
        let window = SpeechWindow(id: "w-snap", sessionID: UUID(), epochID: UUID(), analysisAnchor: 0,
            coreFrames: frameRange, contextFrames: ctxRange, modelCoreFrames: frameRange, modelContextFrames: ctxRange,
            sources: [], replayInputManifestHashes: [], configurationFingerprint: "test")
        let parts = try #require(try jittered.speakerParts(text: jittered.text, window: window))
        // Leading onset 1.10s (50ms before 1.15s) and trailing "。" at 5.88s (80ms after 5.80s) must not create nil orphan parts.
        #expect(parts.count == 2)
        #expect(parts.map(\.text) == ["明天见。", "好的没问题。"])
        #expect(parts[0].evidence?.localSpeaker == 1)
        #expect(parts[1].evidence?.localSpeaker == 2)
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_TURN_TEST_MODEL_DIRECTORY"] != nil))
struct SpeakerTurnRecordingTests {
    @Test func priorRecordingRunsThroughProductionTurnDecoding() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(environment["MOMO_TURN_TEST_OUTPUT"]))
        let wave = try #require(SherpaOnnxReadWave(try #require(environment["MOMO_TURN_TEST_WAV"])))
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        let pcm = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
            .map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) }
        var writer = try PCM16SegmentWriter(directory: root.appendingPathComponent("input"), sessionID: UUID(),
            epochID: UUID(), sourceDeviceID: UUID(), sourceBuild: "turn-regression", sourceKind: .fixture,
            sampleRate: 16_000, targetFrames: 960_000, wallClockAnchor: Date(timeIntervalSince1970: 0), timezoneOffset: 28_800)
        var chunks = try writer.append(pcm)
        if let tail = try writer.finish() { chunks.append(tail) }
        let inputs = chunks.map { SpeechAudioInput(envelope: $0.envelope, audioURL: $0.audioURL) }
        let input = try SpeechInputSet(inputs, anchor: 0)
        let bundle = try SpeechModelBundle.load(from: URL(fileURLWithPath: #require(environment["MOMO_TURN_TEST_MODEL_DIRECTORY"])))
        let config = try SpeechConfiguration()
        let engine = try SpeechEngine(bundle: bundle, configuration: config, continuousArchive: true,
            recognitionBackend: .sherpaCoreML, coreMLCacheDirectory: root.appendingPathComponent("cache"),
            speakerDirectory: URL(fileURLWithPath: #require(environment["MOMO_TURN_TEST_SPEAKERS"])))
        let planner = WindowPlanner(configuration: config, fingerprint: engine.configurationFingerprint)
        var results: [SpeechRecognition] = []
        for start in stride(from: Int64(0), to: input.modelFrameCount, by: 160_000) {
            let frames = try FrameRange(start: start, count: min(160_000, input.modelFrameCount - start))
            let window = try planner.makeWindow(core: frames, context: frames, input: input)
            let result = try await engine.transcribe(window: window, inputs: inputs)
            #expect(result.speakerFailure == nil)
            if let parts = try result.speakerParts(text: engine.archiveText(result, window: window), window: window) {
                #expect(parts.map(\.text).joined() == result.text)
                #expect(parts.first?.frames.start == window.coreFrames.start)
                #expect(parts.last?.frames.end == window.coreFrames.end)
            }
            results.append(result)
        }
        #expect(results.contains { ($0.speakerTurns?.count ?? 0) > 1 })
        try WireJSON.encode(results).write(to: root.appendingPathComponent("prior-recording-turns.json"))
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MOMO_SPEAKER_MODEL_DIRECTORY"] != nil))
struct SpeakerNativeTests {
    @Test func realRecordingAndSilenceUseTheProductionCoreMLAdapter() throws {
        let environment = ProcessInfo.processInfo.environment
        let models = URL(fileURLWithPath: try #require(environment["MOMO_SPEAKER_MODEL_DIRECTORY"]))
        let audio = try #require(environment["MOMO_SPEAKER_TEST_WAV"])
        let cache = URL(fileURLWithPath: try #require(environment["MOMO_SPEAKER_TEST_OUTPUT"]))
        let attempt = SpeechAttempt()
        let runtime = try SpeakerRuntime(directory: models, cacheRoot: cache, attempt: attempt)
        let wave = try #require(SherpaOnnxReadWave(audio))
        defer { SherpaOnnxFreeWave(wave) }
        #expect(wave.pointee.sample_rate == 16_000)
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: Int(wave.pointee.num_samples)))
        let started = Date()
        let evidence = try runtime.analyze(samples, attempt: attempt)
        #expect(evidence.contains { $0.hasVoiceprint && $0.cleanSeconds >= 3 })
        #expect(evidence.allSatisfy { $0.start >= 0 && $0.end <= Double(samples.count) / 16_000 && $0.end > $0.start })
        #expect(evidence.allSatisfy { $0.embedding.isEmpty || $0.hasVoiceprint })
        if samples.count > 160_000, Set(evidence.map(\.localSpeaker).filter { $0 > 0 }).count >= 2 {
            // Overlapping powerset stitching keeps localSpeaker tracks in [1..3] across a >10s block.
            #expect(evidence.allSatisfy { $0.localSpeaker < 0 || (1...3).contains($0.localSpeaker) })
        }
        try WireJSON.encode(evidence).write(to: cache.appendingPathComponent("production-speaker-evidence.json"))
        print("Speaker adapter: audio=\(samples.count / 16000)s, segments=\(evidence.count), embeddings=\(evidence.filter(\.hasVoiceprint).count), elapsed=\(Date().timeIntervalSince(started))s")
        #expect(try runtime.analyze(Array(repeating: 0, count: 160_000), attempt: attempt).isEmpty)
        attempt.cancel()
        #expect(throws: SpeechError.self) { try runtime.analyze(samples, attempt: attempt) }
    }
}
