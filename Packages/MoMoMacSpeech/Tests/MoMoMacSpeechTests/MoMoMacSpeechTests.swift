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
            let tx = try moss.transcribe(samples: decoded.samples)
            XCTAssertFalse(tx.rawText.isEmpty)
            XCTAssertFalse(tx.segments.isEmpty)
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
