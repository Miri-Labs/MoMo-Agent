import Foundation
import XCTest
@testable import MoMoMacSpeech

final class MoMoMacSpeechTests: XCTestCase {
    func testMOSSSegmentParser() {
        let raw = "[0.15][S01]你好，我们今天讨论 MoMo Agent 的架构。[3.40]\n[3.55][S02]好的，我觉得声纹绑定很实用。[6.10]"
        let segs = MOSSTranscriber.parseSegments(raw, clipDurationSec: 10.0)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].speakerTag, "S01")
        XCTAssertEqual(segs[0].startSec, 0.15, accuracy: 0.001)
        XCTAssertEqual(segs[0].endSec, 3.40, accuracy: 0.001)
        XCTAssertEqual(segs[0].text, "你好，我们今天讨论 MoMo Agent 的架构。")
        XCTAssertEqual(segs[1].speakerTag, "S02")
        XCTAssertEqual(segs[1].text, "好的，我觉得声纹绑定很实用。")
    }

    func testReDimNetBucketSelection() {
        XCTAssertEqual(ReDimNetMelFrontend.selectBucket(forSampleCount: 16_000 * 2), 200)
        XCTAssertEqual(ReDimNetMelFrontend.selectBucket(forSampleCount: 16_000 * 4), 400)
        XCTAssertEqual(ReDimNetMelFrontend.selectBucket(forSampleCount: 16_000 * 6), 600)
    }

    func testBPEQwenTokenizerAddedAndSpecialTokens() throws {
        let mossDir = CoreMLBundleManager.defaultModelsRoot.appendingPathComponent("MOSSCoreML")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: mossDir.appendingPathComponent("vocab.json").path), "MOSSCoreML bundle missing")
        let tok = try BPEQwenTokenizer(directory: mossDir)
        let special = tok.encode("<|im_start|>user\n<|audio_start|><|audio_end|><|im_end|>")
        XCTAssertEqual(special.first, 151644, "Expected <|im_start|> token ID 151644")
        XCTAssertEqual(special.last, 151645, "Expected <|im_end|> token ID 151645")
        XCTAssertTrue(special.contains(151669) && special.contains(151670), "Missing <|audio_start|>(151669) / <|audio_end|>(151670) special tokens")

        let sample = "今天讨论 MoMo Agent 声纹识别与 CoreML 加速！"
        let ids = tok.encode(sample)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(tok.decode(ids), sample)
    }

    func testMelFrontendsFiniteAndDeterministic() throws {
        let root = CoreMLBundleManager.defaultModelsRoot
        let mossMelURL = root.appendingPathComponent("MOSSCoreML/whisper_mel_filters_80x201.bin")
        let redimMelURL = root.appendingPathComponent("ReDimNet2Plus/mel_filterbank_72x256.bin")
        let redimWinURL = root.appendingPathComponent("ReDimNet2Plus/hamming_window_400.bin")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: mossMelURL.path) &&
            FileManager.default.fileExists(atPath: redimMelURL.path) &&
            FileManager.default.fileExists(atPath: redimWinURL.path),
            "Frontend filterbank assets missing"
        )
        let samples = (0..<32_000).map { i in Float(sin(Double(i) * 0.08)) * 0.25 }

        let wMel = try WhisperMelFrontend(melFiltersURL: mossMelURL)
        let w1 = wMel.extractChunk(samples[...])
        let w2 = wMel.extractChunk(samples[...])
        XCTAssertEqual(w1.count, 80 * 3000)
        XCTAssertEqual(w1, w2)
        XCTAssertTrue(w1.allSatisfy(\.isFinite))

        let rMel = try ReDimNetMelFrontend(melFilterbankURL: redimMelURL, windowURL: redimWinURL)
        let r1 = rMel.extractForBucket(samples, bucketFrames: 600)
        let r2 = rMel.extractForBucket(samples, bucketFrames: 600)
        XCTAssertEqual(r1.count, 72 * 600)
        XCTAssertEqual(r1, r2)
        XCTAssertTrue(r1.allSatisfy(\.isFinite))
    }

    func testSileroVADDeterminismAndPingPongReset() throws {
        let vadURL = CoreMLBundleManager.defaultModelsRoot.appendingPathComponent("SileroVAD/SileroVAD.mlmodelc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: vadURL.path), "SileroVAD bundle missing")
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let zhWav = repoRoot.appendingPathComponent("Models/TestFixtures/zh.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: zhWav.path), "zh.wav fixture missing")

        let decoded = try AudioDecoder.decodeFile(at: zhWav)
        let vad = SileroVADRunner(modelURL: vadURL)
        let r1 = vad.detectSpeech(samples: decoded.samples)
        let r2 = vad.detectSpeech(samples: decoded.samples)
        XCTAssertTrue(r1.hasSpeech)
        XCTAssertEqual(r1.speechSeconds, r2.speechSeconds, accuracy: 1e-6)
        XCTAssertEqual(r1.intervals.count, r2.intervals.count)
    }

    func testSileroVADAndReDimNetCoreMLRealAudio() throws {
        let modelsRoot = CoreMLBundleManager.defaultModelsRoot
        let mgr = CoreMLBundleManager(modelsRoot: modelsRoot, idleEvictionSeconds: 0)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let zhWav = repoRoot.appendingPathComponent("Models/TestFixtures/zh.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: zhWav.path), "zh.wav fixture missing")

        let decoded = try AudioDecoder.decodeFile(at: zhWav)
        XCTAssertEqual(decoded.sampleRate, 16_000)
        XCTAssertGreaterThan(decoded.durationSeconds, 2.0)

        let vad = mgr.getVAD()
        let vadRes = vad.detectSpeech(samples: decoded.samples)
        XCTAssertTrue(vadRes.hasSpeech)
        XCTAssertGreaterThan(vadRes.speechSeconds, 1.0)

        if mgr.redimnetAvailable {
            let enc = try mgr.getReDimNet()
            XCTAssertEqual(enc.acceleratorMask, 1, "ReDimNet2+ should run on ANE/GPU")
            let emb1 = try enc.extractEmbedding(samples: decoded.samples, vad: vad)
            XCTAssertEqual(emb1.embedding.count, 192)
            let norm = sqrt(emb1.embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
            XCTAssertEqual(norm, 1.0, accuracy: 1e-4)

            // Same speaker split into two slices should have high self-similarity
            let half = decoded.samples.count / 2
            let firstHalf = Array(decoded.samples[0..<half])
            let secondHalf = Array(decoded.samples[half..<decoded.samples.count])
            if Double(firstHalf.count) / 16_000.0 >= 1.6 && Double(secondHalf.count) / 16_000.0 >= 1.6 {
                let eA = try enc.extractEmbedding(samples: firstHalf, vad: nil, requireMinSeconds: 1.0)
                let eB = try enc.extractEmbedding(samples: secondHalf, vad: nil, requireMinSeconds: 1.0)
                let sim = ReDimNetVoiceEncoder.cosineSimilarity(eA.embedding, eB.embedding)
                XCTAssertGreaterThan(sim, 0.55, "Same-speaker halves cosine too low: \(sim)")
            }
        }

        if mgr.mossAvailable {
            let moss = try mgr.getMOSS()
            XCTAssertEqual(moss.acceleratorMask, 3, "MOSS encoder and decoder should both run on ANE/GPU")
            let tx1 = try moss.transcribe(samples: decoded.samples)
            XCTAssertFalse(tx1.rawText.isEmpty)
            XCTAssertFalse(tx1.segments.isEmpty)

            // Exercise Dual-KV short -> long -> short exclusive MLState switching when Dual-KV bundle is installed
            if moss.shortKvLen > 0 {
                var longSamples = decoded.samples
                longSamples.append(contentsOf: [Float](repeating: 0, count: 16_000 * 80)) // ~85.6s -> forces 4096 KV slot
                let txLong = try moss.transcribe(samples: longSamples)
                XCTAssertFalse(txLong.rawText.isEmpty)
                let tx2 = try moss.transcribe(samples: decoded.samples)
                XCTAssertEqual(tx2.rawText, tx1.rawText, "Dual-KV short->long->short round-trip must be deterministic")
            }
        }
    }

    func testLoopbackHTTPServerHealthAndEmbed() async throws {
        let mgr = CoreMLBundleManager(modelsRoot: CoreMLBundleManager.defaultModelsRoot, idleEvictionSeconds: 0)
        let port = UInt16.random(in: 24000...29000)
        let token = "test-secret-token"
        let server = MacSpeechHTTPServer(port: port, authToken: token, bundleManager: mgr)
        try server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(port)/internal/v1/health")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (bodyData, resp) = try await URLSession.shared.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(statusCode, 200)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertNotNil(obj["models_root"])
        XCTAssertNotNil(obj["redimnet_available"])
        XCTAssertEqual(obj["silero_available"] as? Bool, true)
    }
}
