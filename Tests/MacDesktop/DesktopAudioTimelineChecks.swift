import AVFoundation
import Foundation
import MoMoAgentClient

@main
enum DesktopAudioTimelineChecks {
    private static func makeChunk(
        id: String,
        seq: Int,
        recordedAt: Double,
        duration: Double = 60.0,
        exists: Bool = true,
        path: String? = "/tmp/fake.m4a"
    ) throws -> SourceAudioChunkItem {
        let obj: [String: Any?] = [
            "chunk_id": id,
            "chunk_seq": seq,
            "recorded_at": recordedAt,
            "duration_sec": duration,
            "end_at": recordedAt + duration,
            "codec": "aac",
            "byte_size": 120_000,
            "exists": exists,
            "path": path,
            "vad_status": "speech",
            "transcription_status": "done",
        ]
        let data = try JSONSerialization.data(withJSONObject: obj.compactMapValues { $0 })
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SourceAudioChunkItem.self, from: data)
    }

    private static func writeSineWav(to url: URL, durationSec: Double = 1.5, sampleRate: Int = 16_000) throws {
        let frameCount = Int(Double(sampleRate) * durationSec)
        var pcm = Data(capacity: frameCount * 2)
        for i in 0..<frameCount {
            let sample = Int16(sin(Double(i) * 2.0 * .pi * 440.0 / Double(sampleRate)) * 8_000)
            var le = sample.littleEndian
            withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func appendASCII(_ s: String) { wav.append(contentsOf: s.utf8) }
        func appendU32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) } }

        let dataSize = UInt32(pcm.count)
        appendASCII("RIFF")
        appendU32(36 + dataSize)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        appendASCII("data")
        appendU32(dataSize)
        wav.append(pcm)
        try wav.write(to: url)
    }

    @MainActor
    static func main() async throws {
        // 1. Contiguous chunks & cross-chunk sentence range mapping
        let c0 = try makeChunk(id: "c0", seq: 0, recordedAt: 1_000)
        let c1 = try makeChunk(id: "c1", seq: 1, recordedAt: 1_060)
        let cGap = try makeChunk(id: "c2", seq: 2, recordedAt: 2_000) // After a 15-min pause
        let missing = try makeChunk(id: "c_missing", seq: 3, recordedAt: 3_000, exists: false)

        let full = DesktopAudioTimeline(chunks: [cGap, c0, c1, missing])
        precondition(full.segments.map(\.chunk.chunkId) == ["c0", "c1", "c2"])
        precondition(abs(full.totalDurationSec - 180.0) < 0.001)

        // Single-chunk sentence [1012.0, 1018.5] -> [12.0, 18.65]
        let r1 = full.spanOffsetRange(startWallClock: 1_012.0, endWallClock: 1_018.5)!
        precondition(abs(r1.startOffset - 12.0) < 0.001)
        precondition(abs((r1.endOffset ?? 0) - 18.65) < 0.001)

        // Cross-chunk sentence [1058.0, 1064.0] across c0 -> c1 -> [58.0, 64.15]
        let rCross = full.spanOffsetRange(startWallClock: 1_058.0, endWallClock: 1_064.0)!
        precondition(abs(rCross.startOffset - 58.0) < 0.001)
        precondition(abs((rCross.endOffset ?? 0) - 64.15) < 0.001)

        // Sentence ending right before a pause gap [1116.0, 1120.0] clamps at 120.0 (never jumps to 2000s!)
        let rBeforeGap = full.spanOffsetRange(startWallClock: 1_116.0, endWallClock: 1_120.0)!
        precondition(abs(rBeforeGap.startOffset - 116.0) < 0.001)
        precondition(abs((rBeforeGap.endOffset ?? 0) - 120.0) < 0.001)

        // Missing/unrecorded interval [1500, 1505] or [3010, 3015] must NOT match a later/earlier chunk
        precondition(!full.canPlay(startWallClock: 1_500.0, endWallClock: 1_505.0))
        precondition(!full.canPlay(startWallClock: 3_010.0, endWallClock: 3_015.0))

        // Wall-clock recovery across gap: offset 130s -> 10s into cGap (2000 + 10 = 2010)
        precondition(abs((full.wallClock(forOffset: 130.0) ?? 0) - 2_010.0) < 0.001)

        // 2. Window scoping excludes distant chunks and never falls back to wrong-hour audio
        let winScoped = DesktopAudioTimeline(chunks: [c0, c1, cGap], windowStart: 2_005, windowEnd: 2_045)
        precondition(winScoped.segments.map(\.chunk.chunkId) == ["c2"])
        let emptyWin = DesktopAudioTimeline(chunks: [c0, c1], windowStart: 5_000, windowEnd: 5_060)
        precondition(emptyWin.isEmpty)

        // 3. Binary search activeSpanID tracking
        let spans = [
            DesktopAudioSpanInterval(id: "s1", startWallClock: 1_005, endWallClock: 1_010),
            DesktopAudioSpanInterval(id: "s2", startWallClock: 1_015, endWallClock: 1_022),
            DesktopAudioSpanInterval(id: "s3", startWallClock: 2_002, endWallClock: 2_009),
        ]
        precondition(full.activeSpanID(atWallClock: 1_007.5, spans: spans) == "s1")
        precondition(full.activeSpanID(atWallClock: 1_012.5, spans: spans) == nil)
        precondition(full.activeSpanID(atWallClock: 2_005.0, spans: spans) == "s3")

        // 4. DesktopRecordingAudioPlayer toggleSpan state transitions (play -> pause -> resume -> switch)
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("momo-audio-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let wavURL = tmpDir.appendingPathComponent("chunk0.wav")
        try writeSineWav(to: wavURL, durationSec: 2.0)

        let liveChunk = try makeChunk(id: "live0", seq: 0, recordedAt: 10_000, duration: 2.0, exists: true, path: wavURL.path)
        let player = DesktopRecordingAudioPlayer()
        player.load(sourceID: "lib/sess", chunks: [liveChunk], spans: [
            DesktopAudioSpanInterval(id: "spA", startWallClock: 10_000.2, endWallClock: 10_000.9),
            DesktopAudioSpanInterval(id: "spB", startWallClock: 10_001.1, endWallClock: 10_001.8),
        ])
        precondition(player.hasAudio && player.chunksRevision == 1)
        precondition(player.canPlaySpan(startWallClock: 10_000.2, endWallClock: 10_000.9))
        precondition(!player.canPlaySpan(startWallClock: 20_000.0, endWallClock: 20_001.0))

        player.toggleSpan(id: "spA", startWallClock: 10_000.2, endWallClock: 10_000.9)
        precondition(player.activeSpanID == "spA")
        if player.error == nil {
            precondition(player.isPlaying)
            // Clicking same active span pauses while keeping activeSpanID
            player.toggleSpan(id: "spA", startWallClock: 10_000.2, endWallClock: 10_000.9)
            precondition(!player.isPlaying && player.activeSpanID == "spA")
            // Clicking a second span switches immediately to spB
            player.toggleSpan(id: "spB", startWallClock: 10_001.1, endWallClock: 10_001.8)
            precondition(player.isPlaying && player.activeSpanID == "spB")
        }
        player.stop()
        precondition(!player.isPlaying && player.activeSpanID == nil)

        print("Desktop audio timeline and per-span playback checks passed")
    }
}
