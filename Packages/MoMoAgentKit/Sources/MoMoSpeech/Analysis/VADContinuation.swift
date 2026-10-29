import Foundation
import MoMoContracts

/// Detector state belongs to an audio epoch, not to a scheduling ticket.
final class VADContinuation {
    let sessionID: UUID
    let epochID: UUID
    let threshold: Float
    let origin: Int64
    let rate: Double
    let detector: SherpaVAD
    private(set) var processed: Int64 = 0
    private(set) var pending: [Float] = []
    private(set) var ranges: [Range<Int64>] = []
    private(set) var replayFloor: Int64 = 0
    private(set) var continuousSpeech: Int64 = 0
    private(set) var quietFrames: Int64 = 0
    private(set) var undrainedSpeechFloor: Int64?
    private(set) var lastFlushWasForced = false
    private(set) var finalized = false
    private(set) var rolloverReplayFrames: Int64 = 0
    private let nativeFrameLimit: Int64
    private let warmupFrames: Int64
    private var recentPCM: AnalysisAudioBuffer?
    private var nativeOrigin: Int64 = 0
    private var nativeRangeFloor: Int64 = 0
    private var vadGainHistory: [VADFrameStat] = []
    private var previousVADGain: Float = 1
    private var heldVADGain: Float = 1
    private var energy: [SpeechEnergyFrame] = []

    init(input: SpeechInputSet, origin: Int64, threshold: Float, detector: SherpaVAD,
         nativeFrameLimit: Int64 = 24 * 3_600 * 16_000, warmupFrames: Int64 = 60 * 16_000) {
        precondition(nativeFrameLimit > warmupFrames && nativeFrameLimit < Int64(Int32.max) - 512
            && nativeFrameLimit % 512 == 0 && warmupFrames > 256_000 && warmupFrames % 512 == 0)
        sessionID = input.sessionID; epochID = input.epochID
        rate = input.sampleRate; self.origin = origin
        self.threshold = threshold; self.detector = detector
        self.nativeFrameLimit = nativeFrameLimit; self.warmupFrames = warmupFrames
    }

    var received: Int64 { processed + Int64(pending.count) }

    func offset(_ source: Int64) -> Int64 {
        Int64((Double(source - origin) * 16_000 / rate).rounded(.down))
    }

    func canContinue(_ input: SpeechInputSet, threshold: Float) -> Bool {
        // Other sample rates rebuild the converter from the same origin, preserving its phase.
        rate == 16_000 && input.sampleRate == rate && self.threshold == threshold
            && sessionID == input.sessionID && epochID == input.epochID && !finalized
            && offset(input.start) >= replayFloor
            && offset(input.inputs[0].envelope.manifest.frames.start) <= received
            && offset(input.end) >= received
    }

    func retain(from frame: Int64) {
        replayFloor = max(replayFloor, frame)
        energy.removeAll { $0.start + 512 <= replayFloor }
        ranges = ranges.compactMap { range in
            let lower = max(range.lowerBound, replayFloor)
            return range.upperBound > lower ? lower..<range.upperBound : nil
        }
    }

    func append(_ samples: [Float], at frame: Int64) throws {
        guard frame <= received else { throw SpeechError.inputGap(expected: received, actual: frame) }
        let skipped = min(samples.count, Int(received - frame))
        pending.append(contentsOf: samples.dropFirst(skipped))
    }

    /// Consume only PCM available to this caller. A replay never feeds the detector twice.
    func step(through frame: Int64) throws -> Bool {
        guard pending.count >= 512, processed + 512 <= frame else { return false }
        // Sherpa uses Int32 positions internally. A day-long detector rolls over with
        // a warm prefix, independently of file, task or checkpoint boundaries.
        if processed - nativeOrigin >= nativeFrameLimit { try rollOverNativeClock() }
        if recentPCM == nil, processed - nativeOrigin >= nativeFrameLimit - warmupFrames {
            recentPCM = AnalysisAudioBuffer(capacity: Int(warmupFrames), start: processed)
        }
        let samples = Array(pending.prefix(512))
        let normalized = normalizeForVAD(samples, at: origin + processed)
        try detector.accept(normalized)
        recentPCM?.append(normalized)
        pending.removeFirst(512)
        processed += 512
        let finished = try detector.drain()
        if !finished.isEmpty {
            appendRanges(finished)
            lastFlushWasForced = false
            if !detector.speechDetected { undrainedSpeechFloor = nil }
        }
        if detector.speechDetected {
            quietFrames = 0
            if undrainedSpeechFloor == nil { undrainedSpeechFloor = max(0, processed - 512 - 32_000) }
            continuousSpeech += 512
            if continuousSpeech >= 256_000 {
                detector.flush(); appendRanges(try detector.drain())
                continuousSpeech = 0; lastFlushWasForced = true; undrainedSpeechFloor = nil
            }
        } else {
            continuousSpeech = 0
            quietFrames += 512
            if quietFrames >= 32_000 {
                lastFlushWasForced = false
                undrainedSpeechFloor = nil
            }
        }
        return true
    }

    func finish(padTail: Bool = true) throws {
        if padTail, !pending.isEmpty {
            pending += [Float](repeating: 0, count: 512 - pending.count)
            _ = try step(through: processed + 512)
        }
        detector.flush()
        appendRanges(try detector.drain())
        undrainedSpeechFloor = nil
        finalized = padTail
    }

    func relativeRanges(from frame: Int64, through end: Int64) -> [Range<Int64>] {
        ranges.compactMap {
            let lower = max(frame, $0.lowerBound), upper = min(end, $0.upperBound)
            return upper > lower ? (lower - frame)..<(upper - frame) : nil
        }
    }

    func relativeEnergy(from frame: Int64, through end: Int64) -> [SpeechEnergyFrame] {
        energy.filter { $0.start >= frame && $0.start + 512 <= end }
            .map { SpeechEnergyFrame(start: $0.start - frame, rms: $0.rms) }
    }

    private func appendRanges(_ added: [Range<Int64>]) {
        for local in added {
            let lower = max(replayFloor, nativeRangeFloor, local.lowerBound + nativeOrigin)
            let upper = local.upperBound + nativeOrigin
            guard upper > lower else { continue }
            let range = lower..<upper
            if let previous = ranges.last, range.lowerBound <= previous.upperBound {
                ranges[ranges.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else { ranges.append(range) }
        }
    }

    private func rollOverNativeClock() throws {
        let wasSpeech = detector.speechDetected
        detector.flush()
        appendRanges(try detector.drain())
        // Native Flush can end one 512-sample frame before the consumed boundary.
        // Preserve that real audio before resetting the native clock mid-utterance.
        if wasSpeech, let tail = ranges.last, processed > tail.upperBound,
           processed - tail.upperBound <= 512 {
            ranges[ranges.count - 1] = tail.lowerBound..<processed
        }
        let start = processed - warmupFrames
        guard let samples = recentPCM?.samples(in: try FrameRange(start: start, count: warmupFrames)) else {
            throw SpeechError.incompatibleCheckpoint
        }
        detector.reset()
        recentPCM = nil
        nativeOrigin = start; nativeRangeFloor = processed
        continuousSpeech = 0
        for offset in stride(from: 0, to: samples.count, by: 512) {
            try detector.accept(Array(samples[offset..<(offset + 512)]))
            _ = try detector.drain()
            continuousSpeech = detector.speechDetected ? continuousSpeech + 512 : 0
            if continuousSpeech >= 256_000 {
                detector.flush(); _ = try detector.drain(); continuousSpeech = 0
            }
        }
        rolloverReplayFrames += warmupFrames
        quietFrames = detector.speechDetected ? 0 : quietFrames
        undrainedSpeechFloor = detector.speechDetected ? max(0, processed - continuousSpeech - 32_000) : nil
        lastFlushWasForced = wasSpeech || detector.speechDetected
    }

    /// Causal 1.024s P98 envelope normalizer for sleeve-attenuated Watch speech.
    /// Normal-volume speech (maxAbs >= 0.25) and low-crest stationary noise stay at gain 1.0.
    private func normalizeForVAD(_ samples: [Float], at globalFrame: Int64) -> [Float] {
        var maxAbs: Float = 0
        var sumSq: Double = 0
        var magnitudes = [Float]()
        magnitudes.reserveCapacity(512)
        for sample in samples {
            let mag = abs(sample)
            if mag > maxAbs { maxAbs = mag }
            sumSq += Double(sample) * Double(sample)
            magnitudes.append(mag)
        }
        magnitudes.sort()
        let stat = VADFrameStat(maxAbs: maxAbs, p90: magnitudes[460], sumSq: sumSq)
        energy.append(SpeechEnergyFrame(start: processed, rms: Float((sumSq / 512).squareRoot())))
        if vadGainHistory.count == 32 { vadGainHistory.removeFirst() }
        vadGainHistory.append(stat)
        if vadGainHistory.count == 1 || globalFrame % 8_192 == 0 {
            var windowMax: Float = 0
            var windowSumSq: Double = 0
            var p90s = [Float]()
            p90s.reserveCapacity(vadGainHistory.count)
            for item in vadGainHistory {
                if item.maxAbs > windowMax { windowMax = item.maxAbs }
                windowSumSq += item.sumSq
                p90s.append(item.p90)
            }
            p90s.sort()
            let windowRMS = (windowSumSq / Double(vadGainHistory.count * 512)).squareRoot()
            let windowP98 = p90s[max(0, p90s.count - 2)]
            if windowRMS >= 0.0012 && windowP98 >= 0.002 && windowMax < 0.25 && Double(windowMax) >= 2.5 * windowRMS {
                heldVADGain = min(45.0, max(1.0, 0.80 / windowP98))
            } else {
                heldVADGain = 1.0
            }
        }
        let targetGain = heldVADGain
        if targetGain == 1.0 && previousVADGain == 1.0 {
            return samples
        }
        var output = [Float]()
        output.reserveCapacity(512)
        for index in 0..<512 {
            let alpha = Float(index) / 512.0
            let gain = previousVADGain + (targetGain - previousVADGain) * alpha
            output.append(tanh(samples[index] * gain))
        }
        previousVADGain = targetGain
        return output
    }
}

private struct VADFrameStat {
    let maxAbs: Float
    let p90: Float
    let sumSq: Double
}
