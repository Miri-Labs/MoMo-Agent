import CMoMoMacSpeechCoreML
import Foundation

public struct SpeakerEmbeddingResult: Codable, Sendable {
    public let embedding: [Float] // 192-d L2-normalized
    public let cleanSeconds: Double
    public let snrDb: Double
    public let rmsDb: Double
    public let bucketFrames: Int
    public let latencyMs: Double
}

public struct SpeakerSegmentInput: Codable, Sendable {
    public let speakerTag: String
    public let startSec: Double
    public let endSec: Double

    public init(speakerTag: String, startSec: Double, endSec: Double) {
        self.speakerTag = speakerTag
        self.startSec = startSec
        self.endSec = endSec
    }
}

public struct SpeakerClusterEmbedding: Codable, Sendable {
    public let speakerTag: String
    public let embedding: [Float]
    public let cleanSeconds: Double
    public let snrDb: Double
    public let sampleStartSec: Double
    public let sampleEndSec: Double
}

private struct ReDimNetBundleConfig: Decodable {
    let sampleRate: Int
    let embeddingDim: Int
    let timeBuckets: [Int]
    let melFilterbankFile: String
    let windowFile: String
}

/// Native Apple Silicon CoreML (ANE) ReDimNet2+ LMFT B6 (192-d) speaker embedding engine.
/// Uses SpeechRoster-inspired clean non-overlapping center-6s sampling and static ANE buckets (200/400/600).
public final class ReDimNetVoiceEncoder: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let embeddingDim = 192
    public static let minCleanSeconds = 1.6
    public static let maxSampleSeconds = 60.0

    private let config: ReDimNetBundleConfig
    private let frontend: ReDimNetMelFrontend
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public var acceleratorMask: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return handle.map { MoMoReDimNetAcceleratorMask($0) } ?? 0
    }

    public init(bundleDirectory: URL) throws {
        let cfgData = try Data(contentsOf: bundleDirectory.appendingPathComponent("redimnet2_config.json"))
        self.config = try JSONDecoder().decode(ReDimNetBundleConfig.self, from: cfgData)
        self.frontend = try ReDimNetMelFrontend(
            melFilterbankURL: bundleDirectory.appendingPathComponent(config.melFilterbankFile),
            windowURL: bundleDirectory.appendingPathComponent(config.windowFile)
        )
        let mlcPath = bundleDirectory.appendingPathComponent("ReDimNet2Plus.mlmodelc").path
        var errBuf = [CChar](repeating: 0, count: 1024)
        guard let h = MoMoReDimNetCreate(mlcPath, &errBuf, errBuf.count) else {
            let msg = errBuf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "unknown"
            }
            throw SpeechEngineError.inferenceFailed("MoMoReDimNetCreate failed: \(msg)")
        }
        self.handle = h
    }

    deinit {
        if let h = handle {
            MoMoReDimNetDestroy(h)
        }
    }

    /// Extracts a 192-d L2-normalized voiceprint embedding from a clean audio clip.
    /// If `vad` is provided, strips silence first and checks minimum clean speech duration.
    public func extractEmbedding(
        samples: [Float],
        vad: SileroVADRunner? = nil,
        requireMinSeconds: Double = ReDimNetVoiceEncoder.minCleanSeconds
    ) throws -> SpeakerEmbeddingResult {
        let clipped: [Float]
        let maxSamples = Int(Self.maxSampleSeconds * Double(Self.sampleRate))
        if samples.count > maxSamples {
            clipped = Array(samples.prefix(maxSamples))
        } else {
            clipped = samples
        }

        let cleanSamples: [Float]
        let cleanSec: Double
        if let vad {
            let extracted = vad.extractCleanSpeech(clipped, threshold: 0.40)
            if extracted.cleanSeconds >= requireMinSeconds {
                cleanSamples = extracted.cleanSamples
                cleanSec = extracted.cleanSeconds
            } else {
                // Fall back to full clip if clip itself is short & non-silent
                let dur = Double(clipped.count) / Double(Self.sampleRate)
                guard dur >= requireMinSeconds else {
                    throw SpeechEngineError.audioTooShort(extracted.cleanSeconds)
                }
                cleanSamples = clipped
                cleanSec = dur
            }
        } else {
            let dur = Double(clipped.count) / Double(Self.sampleRate)
            guard dur >= requireMinSeconds else {
                throw SpeechEngineError.audioTooShort(dur)
            }
            cleanSamples = clipped
            cleanSec = dur
        }

        let stats = AudioDecoder.computeSignalStats(cleanSamples)

        // If clean speech > 8s, average embeddings from up to 3 evenly spaced 6s windows for higher SNR robustness
        let t0 = CFAbsoluteTimeGetCurrent()
        let emb: [Float]
        let usedBucket: Int
        if cleanSec > 9.0 {
            let winSamples = 6 * Self.sampleRate
            let positions = [
                0,
                max(0, (cleanSamples.count - winSamples) / 2),
                max(0, cleanSamples.count - winSamples)
            ]
            var acc = [Double](repeating: 0, count: Self.embeddingDim)
            for pos in positions {
                let slice = Array(cleanSamples[pos..<min(cleanSamples.count, pos + winSamples)])
                let e = try inferBucket(slice, bucketFrames: 600)
                for i in 0..<Self.embeddingDim { acc[i] += Double(e[i]) }
            }
            emb = Self.l2Normalize(acc.map(Float.init))
            usedBucket = 600
        } else {
            let bucket = ReDimNetMelFrontend.selectBucket(forSampleCount: cleanSamples.count)
            emb = try inferBucket(cleanSamples, bucketFrames: bucket)
            usedBucket = bucket
        }
        let latencyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        return SpeakerEmbeddingResult(
            embedding: emb,
            cleanSeconds: cleanSec,
            snrDb: stats.snrDb,
            rmsDb: stats.rmsDb,
            bucketFrames: usedBucket,
            latencyMs: latencyMs
        )
    }

    /// Given a diarized window's segments (from MOSS), selects clean non-overlapping intervals
    /// (up to 6s centered on the cleanest intervals per speaker tag) and extracts one 192-d vector per speaker tag.
    public func extractPerSpeakerEmbeddings(
        windowSamples: [Float],
        segments: [SpeakerSegmentInput],
        vad: SileroVADRunner? = nil
    ) -> [SpeakerClusterEmbedding] {
        // Group segments by speakerTag
        var byTag: [String: [SpeakerSegmentInput]] = [:]
        for seg in segments {
            byTag[seg.speakerTag, default: []].append(seg)
        }

        var results: [SpeakerClusterEmbedding] = []
        for (tag, spkSegs) in byTag.sorted(by: { $0.key < $1.key }) {
            let otherSegs = segments.filter { $0.speakerTag != tag }
            // Filter out overlapping intervals (cross-talk protection inspired by SpeechRoster voice_windows)
            var cleanSpans: [(start: Double, end: Double, dur: Double)] = []
            for seg in spkSegs {
                let trimmed = subtractOverlaps(start: seg.startSec, end: seg.endSec, others: otherSegs)
                for span in trimmed where (span.end - span.start) >= 0.6 {
                    cleanSpans.append((span.start, span.end, span.end - span.start))
                }
            }
            // Fallback to raw spans if everything had minor overlap
            if cleanSpans.isEmpty {
                cleanSpans = spkSegs
                    .filter { ($0.endSec - $0.startSec) >= 0.8 }
                    .map { ($0.startSec, $0.endSec, $0.endSec - $0.startSec) }
            }
            guard !cleanSpans.isEmpty else { continue }

            // Sort longest first and gather up to 6.0s of center-cropped clean audio
            cleanSpans.sort { $0.dur > $1.dur }
            var gathered: [Float] = []
            var totalSec = 0.0
            var bestStart = cleanSpans[0].start
            var bestEnd = cleanSpans[0].end

            for span in cleanSpans {
                let remaining = 6.0 - totalSec
                if remaining <= 0.25 { break }
                let s: Double
                let e: Double
                if span.dur > remaining {
                    let mid = (span.start + span.end) * 0.5
                    s = max(span.start, mid - remaining * 0.5)
                    e = min(span.end, s + remaining)
                } else {
                    s = span.start
                    e = span.end
                }
                let slice = AudioDecoder.slice(windowSamples, startSec: s, endSec: e)
                if !slice.isEmpty {
                    if gathered.isEmpty {
                        bestStart = s
                        bestEnd = e
                    }
                    gathered.append(contentsOf: slice)
                    totalSec += Double(slice.count) / Double(Self.sampleRate)
                }
            }

            guard totalSec >= 1.2 else { continue }
            if let embRes = try? extractEmbedding(samples: gathered, vad: vad, requireMinSeconds: 1.0) {
                results.append(SpeakerClusterEmbedding(
                    speakerTag: tag,
                    embedding: embRes.embedding,
                    cleanSeconds: embRes.cleanSeconds,
                    snrDb: embRes.snrDb,
                    sampleStartSec: bestStart,
                    sampleEndSec: bestEnd
                ))
            }
        }
        return results
    }

    // MARK: - Private

    private func inferBucket(_ samples: [Float], bucketFrames: Int) throws -> [Float] {
        let mel = frontend.extractForBucket(samples, bucketFrames: bucketFrames)
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw SpeechEngineError.inferenceFailed("ReDimNet2+ handle closed")
        }
        var out = [Float](repeating: 0, count: Self.embeddingDim)
        var errBuf = [CChar](repeating: 0, count: 1024)
        let rc = mel.withUnsafeBufferPointer { melPtr in
            out.withUnsafeMutableBufferPointer { outPtr in
                MoMoReDimNetEmbed(h, melPtr.baseAddress!, Int32(bucketFrames), outPtr.baseAddress!, &errBuf, errBuf.count)
            }
        }
        if rc != 0 {
            let msg = errBuf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "unknown"
            }
            throw SpeechEngineError.inferenceFailed("ReDimNetEmbed failed: \(msg)")
        }
        return out
    }

    private func subtractOverlaps(
        start: Double,
        end: Double,
        others: [SpeakerSegmentInput]
    ) -> [(start: Double, end: Double)] {
        var intervals: [(start: Double, end: Double)] = [(start, end)]
        let pad = 0.08
        for o in others {
            let os = o.startSec - pad
            let oe = o.endSec + pad
            var next: [(start: Double, end: Double)] = []
            for iv in intervals {
                if oe <= iv.start || os >= iv.end {
                    next.append(iv)
                } else {
                    if os > iv.start { next.append((iv.start, os)) }
                    if oe < iv.end { next.append((oe, iv.end)) }
                }
            }
            intervals = next
            if intervals.isEmpty { break }
        }
        return intervals
    }

    public static func l2Normalize(_ v: [Float]) -> [Float] {
        var sq = 0.0
        for x in v { sq += Double(x) * Double(x) }
        guard sq > 1e-12 else { return v }
        let inv = Float(1.0 / sqrt(sq))
        return v.map { $0 * inv }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0..<a.count {
            let da = Double(a[i])
            let db = Double(b[i])
            dot += da * db
            na += da * da
            nb += db * db
        }
        let denom = sqrt(na * nb)
        return denom > 1e-12 ? Float(dot / denom) : 0
    }
}
