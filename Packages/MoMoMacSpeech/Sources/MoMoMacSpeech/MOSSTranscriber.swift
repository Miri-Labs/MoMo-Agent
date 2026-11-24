import CMoMoMacSpeechCoreML
import Foundation

public struct MOSSSegment: Codable, Equatable, Sendable {
    public let startSec: Double
    public let endSec: Double
    public let speakerTag: String // e.g. "S01", "S02"
    public let text: String

    public init(startSec: Double, endSec: Double, speakerTag: String, text: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.speakerTag = speakerTag
        self.text = text
    }
}

public struct MOSSTranscriptionResult: Codable, Sendable {
    public let segments: [MOSSSegment]
    public let rawText: String
    public let durationSec: Double
    public let encodeSec: Double
    public let decodeSec: Double
    public let totalSec: Double
    public let generatedTokens: Int
    public let possiblyTruncated: Bool
    public let retriedWithBisection: Bool
    public let acceleratorMask: Int32
}

private struct MOSSBundleConfig: Decodable {
    let sampleRate: Int
    let chunkSamples: Int
    let audioMergeSize: Int
    let audioTokensPerSecond: Double
    let timeMarkerEverySeconds: Int
    let enableTimeMarker: Bool
    let audioTokenId: Int32
    let eosTokenId: Int32
    let imEndTokenId: Int32
    let digitTokenIds: [String: Int32]
    let promptPrefixTokenIds: [Int32]
    let defaultPrompt: String
    let maxKvLen: Int32
    let prefillLen: Int32
    let melFiltersFile: String
}

/// Native Apple Silicon CoreML (ANE + GPU) MOSS-Transcribe-Diarize 0.9B engine.
/// Handles 30s Whisper-medium chunk encoding, 5s numeric time-anchor insertion, dynamic hotwords prompting,
/// stateful Qwen3-0.6B chunked prefill + greedy decode, `[start][Sxx]text[end]` parsing, and
/// automatic silence-point bisection retry if truncation or repetition occurs.
public final class MOSSTranscriber: @unchecked Sendable {
    public static let whisperChunkSamples = 480_000
    public static let audioChunkTokens = 375
    public static let hiddenSize = 1024

    private let bundleDir: URL
    private let config: MOSSBundleConfig
    private let tokenizer: BPEQwenTokenizer
    private let melFrontend: WhisperMelFrontend
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public var acceleratorMask: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return handle.map { MoMoMOSSAcceleratorMask($0) } ?? 0
    }

    public var shortKvLen: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return handle.map { MoMoMOSSShortKvLen($0) } ?? 0
    }

    public init(bundleDirectory: URL) throws {
        self.bundleDir = bundleDirectory
        let cfgURL = bundleDirectory.appendingPathComponent("moss_coreml_config.json")
        let cfgData = try Data(contentsOf: cfgURL)
        let cfg = try JSONDecoder().decode(MOSSBundleConfig.self, from: cfgData)
        self.config = cfg

        let encPath = bundleDirectory.appendingPathComponent("MOSSAudioEncoder.mlmodelc").path
        let decPath = bundleDirectory.appendingPathComponent("MOSSDecoder.mlmodelc").path
        let embPath = bundleDirectory.appendingPathComponent("embedding.int8.bin").path
        let melURL = bundleDirectory.appendingPathComponent(cfg.melFiltersFile)

        // Overlap BPEQwenTokenizer + WhisperMelFrontend initialization with CoreML model loading.
        final class InitBox<Value>: @unchecked Sendable {
            var result: Result<Value, Error>?
        }
        let tokBox = InitBox<BPEQwenTokenizer>()
        let melBox = InitBox<WhisperMelFrontend>()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async {
            tokBox.result = Result { try BPEQwenTokenizer(directory: bundleDirectory) }
            group.leave()
        }
        group.enter()
        queue.async {
            melBox.result = Result { try WhisperMelFrontend(melFiltersURL: melURL) }
            group.leave()
        }

        var errBuf = [CChar](repeating: 0, count: 1024)
        let createdHandle = MoMoMOSSCreate(
            encPath,
            decPath,
            embPath,
            cfg.maxKvLen,
            cfg.prefillLen,
            &errBuf,
            errBuf.count
        )
        group.wait()

        guard let h = createdHandle else {
            let msg = errBuf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "unknown"
            }
            throw SpeechEngineError.inferenceFailed("MoMoMOSSCreate failed: \(msg)")
        }
        do {
            self.tokenizer = try tokBox.result!.get()
            self.melFrontend = try melBox.result!.get()
        } catch {
            MoMoMOSSDestroy(h)
            throw error
        }
        self.handle = h
    }

    deinit {
        if let h = handle {
            MoMoMOSSDestroy(h)
        }
    }

    /// Transcribes & diarizes a 16 kHz mono Float32 PCM buffer in a single pass.
    /// Automatically bisects at the deepest quiet point near the midpoint if output appears truncated or loops.
    public func transcribe(
        samples: [Float],
        hotwords: [String] = [],
        languageHint: String? = nil,
        allowBisectRetry: Bool = true
    ) throws -> MOSSTranscriptionResult {
        try transcribeInternal(
            samples: samples,
            hotwords: hotwords,
            languageHint: languageHint,
            bisectDepth: allowBisectRetry ? 2 : 0
        )
    }

    private func transcribeInternal(
        samples: [Float],
        hotwords: [String],
        languageHint: String?,
        bisectDepth: Int
    ) throws -> MOSSTranscriptionResult {
        guard !samples.isEmpty else {
            return MOSSTranscriptionResult(
                segments: [], rawText: "", durationSec: 0, encodeSec: 0, decodeSec: 0, totalSec: 0,
                generatedTokens: 0, possiblyTruncated: false, retriedWithBisection: false,
                acceleratorMask: acceleratorMask
            )
        }

        let dur = Double(samples.count) / Double(config.sampleRate)
        // Ensure prompt + reasonable decode headroom fits inside maxKvLen.
        // At 12.5 audio tokens/sec + time markers (~13 tok/sec), 180s = ~2350 prompt tokens, leaving ~1740 decode tokens.
        let maxSinglePassSec = max(30.0, Double(config.maxKvLen - 1200) / 13.5)
        if dur > maxSinglePassSec && bisectDepth > 0 {
            return try transcribeBisected(
                samples: samples,
                hotwords: hotwords,
                languageHint: languageHint,
                remainingDepth: bisectDepth - 1
            )
        }

        let first = try transcribeSinglePass(samples: samples, hotwords: hotwords, languageHint: languageHint)
        if bisectDepth > 0 && dur >= 25.0 && (first.possiblyTruncated || detectRepetitionAnomaly(first.rawText, segments: first.segments)) {
            return try transcribeBisected(
                samples: samples,
                hotwords: hotwords,
                languageHint: languageHint,
                remainingDepth: bisectDepth - 1
            )
        }
        return first
    }

    /// Lightweight short dictation mode (e.g. iPhone chat voice input <= 120s), returning clean joined text.
    public func dictate(samples: [Float], hotwords: [String] = []) throws -> (text: String, durationSec: Double, elapsedSec: Double) {
        let dur = Double(samples.count) / Double(config.sampleRate)
        let maxSinglePassSec = max(30.0, Double(config.maxKvLen - 1200) / 13.5)
        let res = try transcribe(samples: samples, hotwords: hotwords, allowBisectRetry: dur > maxSinglePassSec)
        let joined: String
        if !res.segments.isEmpty {
            joined = res.segments.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
        } else {
            joined = Self.stripTags(res.rawText)
        }
        return (joined.trimmingCharacters(in: .whitespacesAndNewlines), res.durationSec, res.totalSec)
    }

    // MARK: - Core single-pass execution

    private func transcribeSinglePass(
        samples: [Float],
        hotwords: [String],
        languageHint: String?
    ) throws -> MOSSTranscriptionResult {
        lock.lock()
        defer { lock.unlock() }
        guard let h = handle else {
            throw SpeechEngineError.inferenceFailed("MOSS handle closed")
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let duration = Double(samples.count) / Double(config.sampleRate)
        let strideSamples = 160 * 2 * config.audioMergeSize // 1280 samples per audio token

        // 1. Encode audio in 30s chunks
        var allAudioEmbeds: [Float] = []
        var totalAudioTokens = 0
        var chunkEmbedBuf = [Float](repeating: 0, count: Self.audioChunkTokens * Self.hiddenSize)
        var errBuf = [CChar](repeating: 0, count: 1024)

        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + Self.whisperChunkSamples)
            let chunkCount = end - start
            let tokLen = min(Self.audioChunkTokens, (chunkCount - 1) / strideSamples + 1)
            let mel = melFrontend.extractChunk(samples[start..<end])
            let rc = mel.withUnsafeBufferPointer { melPtr in
                chunkEmbedBuf.withUnsafeMutableBufferPointer { outPtr in
                    MoMoMOSSEncodeAudioChunk(h, melPtr.baseAddress!, outPtr.baseAddress!, &errBuf, errBuf.count)
                }
            }
            if rc != 0 {
                let msg = errBuf.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress.map { String(cString: $0) } ?? "unknown"
                }
                throw SpeechEngineError.inferenceFailed("AudioEncoder failed: \(msg)")
            }
            allAudioEmbeds.append(contentsOf: chunkEmbedBuf.prefix(tokLen * Self.hiddenSize))
            totalAudioTokens += tokLen
            start = end
        }
        let tEnc = CFAbsoluteTimeGetCurrent()

        // 2. Build exact prompt token sequence with 5s numeric time markers & optional hotwords
        let promptSuffixText = buildPromptSuffix(hotwords: hotwords, languageHint: languageHint)
        let suffixIds = tokenizer.encode(promptSuffixText)
        let audioSpanIds = expandAudioTokenIds(audioTokenCount: totalAudioTokens)
        var fullIds: [Int32] = []
        fullIds.reserveCapacity(config.promptPrefixTokenIds.count + audioSpanIds.count + suffixIds.count)
        fullIds.append(contentsOf: config.promptPrefixTokenIds)
        fullIds.append(contentsOf: audioSpanIds)
        fullIds.append(contentsOf: suffixIds)

        let remainingBudget = Int(config.maxKvLen) - fullIds.count
        guard remainingBudget >= 32 else {
            throw SpeechEngineError.inferenceFailed("Prompt tokens (\(fullIds.count)) exceed MOSS max_kv_len (\(config.maxKvLen))")
        }
        let maxNewTokens = min(remainingBudget, max(160, Int(ceil(duration * 18.0))))
        var outIds = [Int32](repeating: 0, count: maxNewTokens)
        var genCount: Int32 = 0
        var truncated: Int32 = 0

        let rc = fullIds.withUnsafeBufferPointer { idPtr in
            allAudioEmbeds.withUnsafeBufferPointer { embPtr in
                outIds.withUnsafeMutableBufferPointer { outPtr in
                    MoMoMOSSGenerate(
                        h,
                        idPtr.baseAddress!,
                        Int32(fullIds.count),
                        config.audioTokenId,
                        embPtr.baseAddress!,
                        Int32(totalAudioTokens),
                        config.eosTokenId,
                        config.imEndTokenId,
                        Int32(maxNewTokens),
                        outPtr.baseAddress!,
                        &genCount,
                        &truncated,
                        &errBuf,
                        errBuf.count
                    )
                }
            }
        }
        if rc != 0 {
            let msg = errBuf.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? "unknown"
            }
            throw SpeechEngineError.inferenceFailed("MOSSGenerate failed: \(msg)")
        }

        let tEnd = CFAbsoluteTimeGetCurrent()
        let actualIds = Array(outIds.prefix(Int(genCount)))
        let rawText = tokenizer.decode(actualIds, skipSpecialTokens: true).trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = Self.parseSegments(rawText, clipDurationSec: duration)

        return MOSSTranscriptionResult(
            segments: segments,
            rawText: rawText,
            durationSec: duration,
            encodeSec: tEnc - t0,
            decodeSec: tEnd - tEnc,
            totalSec: tEnd - t0,
            generatedTokens: actualIds.count,
            possiblyTruncated: truncated != 0,
            retriedWithBisection: false,
            acceleratorMask: MoMoMOSSAcceleratorMask(h)
        )
    }

    private func transcribeBisected(
        samples: [Float],
        hotwords: [String],
        languageHint: String?,
        remainingDepth: Int
    ) throws -> MOSSTranscriptionResult {
        let splitIdx = findQuietSplitIndex(samples)
        let leftSamples = Array(samples[0..<splitIdx])
        let rightSamples = Array(samples[splitIdx..<samples.count])
        let offsetSec = Double(splitIdx) / Double(config.sampleRate)

        let left = try transcribeInternal(samples: leftSamples, hotwords: hotwords, languageHint: languageHint, bisectDepth: remainingDepth)
        let right = try transcribeInternal(samples: rightSamples, hotwords: hotwords, languageHint: languageHint, bisectDepth: remainingDepth)

        // Offset right speaker tags so downstream ReDimNet2+ clustering merges across the split cleanly
        var mergedSegs = left.segments
        for seg in right.segments {
            mergedSegs.append(MOSSSegment(
                startSec: seg.startSec + offsetSec,
                endSec: seg.endSec + offsetSec,
                speakerTag: "B2_\(seg.speakerTag)",
                text: seg.text
            ))
        }
        let joinedRaw = [left.rawText, right.rawText].filter { !$0.isEmpty }.joined(separator: "\n")
        return MOSSTranscriptionResult(
            segments: mergedSegs,
            rawText: joinedRaw,
            durationSec: Double(samples.count) / Double(config.sampleRate),
            encodeSec: left.encodeSec + right.encodeSec,
            decodeSec: left.decodeSec + right.decodeSec,
            totalSec: left.totalSec + right.totalSec,
            generatedTokens: left.generatedTokens + right.generatedTokens,
            possiblyTruncated: left.possiblyTruncated || right.possiblyTruncated,
            retriedWithBisection: true,
            acceleratorMask: left.acceleratorMask
        )
    }

    private func findQuietSplitIndex(_ samples: [Float]) -> Int {
        let n = samples.count
        let lo = Int(Double(n) * 0.35)
        let hi = Int(Double(n) * 0.65)
        let win = 3200 // 200ms energy window
        guard hi - lo > win else { return n / 2 }
        var bestIdx = n / 2
        var bestEnergy = Float.greatestFiniteMagnitude
        var pos = lo
        while pos + win <= hi {
            var e: Float = 0
            for i in pos..<(pos + win) {
                e += samples[i] * samples[i]
            }
            if e < bestEnergy {
                bestEnergy = e
                bestIdx = pos + win / 2
            }
            pos += 1600
        }
        return bestIdx
    }

    // MARK: - Prompt & Parsing Helpers

    private func buildPromptSuffix(hotwords: [String], languageHint: String?) -> String {
        var prompt = config.defaultPrompt
        let cleanHotwords = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanHotwords.isEmpty {
            let unique = Array(NSOrderedSet(array: cleanHotwords)) as? [String] ?? cleanHotwords
            let limited = unique.prefix(32).joined(separator: ", ")
            prompt += "热词提示：\(limited)"
        }
        if let hint = languageHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty, hint != "auto" {
            prompt += "（主要语言：\(hint)）"
        }
        return "<|audio_end|>\n\(prompt)<|im_end|>\n<|im_start|>assistant\n"
    }

    private func expandAudioTokenIds(audioTokenCount: Int) -> [Int32] {
        guard config.enableTimeMarker, config.timeMarkerEverySeconds > 0, audioTokenCount > 0 else {
            return Array(repeating: config.audioTokenId, count: max(0, audioTokenCount))
        }
        let tokensPerMarker = Int(config.audioTokensPerSecond * Double(config.timeMarkerEverySeconds))
        guard tokensPerMarker > 0 else {
            return Array(repeating: config.audioTokenId, count: audioTokenCount)
        }
        let duration = Double(audioTokenCount) / config.audioTokensPerSecond
        var output: [Int32] = []
        output.reserveCapacity(audioTokenCount + 64)
        var consumed = 0
        var sec = config.timeMarkerEverySeconds
        while sec <= Int(duration) {
            let pos = (sec / config.timeMarkerEverySeconds) * tokensPerMarker
            let segLen = pos - consumed
            if segLen > 0 {
                output.append(contentsOf: repeatElement(config.audioTokenId, count: segLen))
                consumed += segLen
            }
            for ch in String(sec) {
                if let did = config.digitTokenIds[String(ch)] {
                    output.append(did)
                }
            }
            sec += config.timeMarkerEverySeconds
        }
        let rem = audioTokenCount - consumed
        if rem > 0 {
            output.append(contentsOf: repeatElement(config.audioTokenId, count: rem))
        }
        return output
    }

    /// Parses MOSS output lines `[0.20][S01]你好世界[2.45]` into structured segments.
    public static func parseSegments(_ rawText: String, clipDurationSec: Double) -> [MOSSSegment] {
        let pattern = #"\[(\d+(?:\.\d+)?)\]\[(S\d+)\](.*?)\[(\d+(?:\.\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsText = rawText as NSString
        let matches = regex.matches(in: rawText, range: NSRange(location: 0, length: nsText.length))
        var out: [MOSSSegment] = []
        out.reserveCapacity(matches.count)
        for m in matches {
            guard m.numberOfRanges == 5 else { continue }
            let sStr = nsText.substring(with: m.range(at: 1))
            let spk = nsText.substring(with: m.range(at: 2))
            let body = nsText.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let eStr = nsText.substring(with: m.range(at: 4))
            guard let sVal = Double(sStr), let eVal = Double(eStr), !body.isEmpty else { continue }
            let clampedStart = max(0.0, min(clipDurationSec, sVal))
            let clampedEnd = max(clampedStart + 0.05, min(clipDurationSec, eVal))
            out.append(MOSSSegment(startSec: clampedStart, endSec: clampedEnd, speakerTag: spk, text: body))
        }
        return out
    }

    public static func stripTags(_ raw: String) -> String {
        let pattern = #"\[\d+(?:\.\d+)?\]|\[S\d+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let range = NSRange(location: 0, length: (raw as NSString).length)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detectRepetitionAnomaly(_ rawText: String, segments: [MOSSSegment]) -> Bool {
        if segments.count >= 6 {
            // Check 4+ consecutive identical short utterances (classic decoder loop)
            var streak = 1
            for i in 1..<segments.count {
                if segments[i].text == segments[i - 1].text && segments[i].text.count >= 2 {
                    streak += 1
                    if streak >= 4 { return true }
                } else {
                    streak = 1
                }
            }
        }
        if rawText.count >= 240 && segments.isEmpty {
            return true
        }
        return false
    }
}
