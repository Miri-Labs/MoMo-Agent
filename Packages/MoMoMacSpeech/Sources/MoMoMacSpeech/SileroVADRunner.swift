import Accelerate
import CoreML
import Foundation

public struct SpeechInterval: Codable, Equatable, Sendable {
    public let startSec: Double
    public let endSec: Double
    public var durationSec: Double { max(0.0, endSec - startSec) }

    public init(startSec: Double, endSec: Double) {
        self.startSec = startSec
        self.endSec = endSec
    }
}

public struct VADResult: Codable, Sendable {
    public let durationSec: Double
    public let speechSeconds: Double
    public let intervals: [SpeechInterval]
    public let hasSpeech: Bool
    public let rmsDb: Double
    public let snrDb: Double
    public let engine: String
}

/// Pure CoreML Silero VAD (16 kHz, 512-sample chunks + 64-sample context + LSTM state [2,1,128]).
/// Includes causal P98 gain normalization for quiet Apple Watch recordings and a safe spectral-energy fallback
/// when the SileroVAD.mlmodelc bundle is unavailable.
public final class SileroVADRunner: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let windowSamples = 512
    public static let contextSamples = 64

    private let model: MLModel?
    private let lock = NSLock()

    public var usesCoreML: Bool { model != nil }

    public init(modelURL: URL?) {
        if let modelURL, FileManager.default.fileExists(atPath: modelURL.path) {
            let cfg = MLModelConfiguration()
            // Tiny LSTM (~1.5 MB) runs in ~0.05 ms/frame on CPU with zero ANE dispatch overhead
            cfg.computeUnits = .cpuOnly
            self.model = try? MLModel(contentsOf: modelURL, configuration: cfg)
        } else {
            self.model = nil
        }
    }

    public func detectSpeech(
        samples: [Float],
        threshold: Double = 0.45,
        minSpeechSec: Double = 0.25,
        minSilenceSec: Double = 0.50,
        padSec: Double = 0.15,
        normalizeQuietInput: Bool = true
    ) -> VADResult {
        let duration = Double(samples.count) / Double(Self.sampleRate)
        let stats = AudioDecoder.computeSignalStats(samples)
        guard samples.count >= Self.windowSamples else {
            return VADResult(
                durationSec: duration,
                speechSeconds: 0,
                intervals: [],
                hasSpeech: false,
                rmsDb: stats.rmsDb,
                snrDb: stats.snrDb,
                engine: model != nil ? "silero_coreml" : "energy_fallback"
            )
        }

        let processed = normalizeQuietInput ? AudioDecoder.applyGentleGainNormalization(samples) : samples
        let probs: [Float]
        let engineName: String
        if let model {
            probs = runCoreMLProbabilities(model: model, samples: processed)
            engineName = "silero_coreml"
        } else {
            probs = runEnergyFallbackProbabilities(samples: processed)
            engineName = "energy_fallback"
        }

        let intervals = hysteresisDecode(
            probs: probs,
            durationSec: duration,
            threshold: Float(threshold),
            minSpeechSec: minSpeechSec,
            minSilenceSec: minSilenceSec,
            padSec: padSec
        )
        let speechSec = intervals.reduce(0.0) { $0 + $1.durationSec }
        return VADResult(
            durationSec: duration,
            speechSeconds: speechSec,
            intervals: intervals,
            hasSpeech: speechSec >= minSpeechSec,
            rmsDb: stats.rmsDb,
            snrDb: stats.snrDb,
            engine: engineName
        )
    }

    /// Concatenates only the speech intervals from `samples` (used before speaker embedding extraction).
    public func extractCleanSpeech(_ samples: [Float], threshold: Double = 0.45) -> (cleanSamples: [Float], cleanSeconds: Double) {
        let res = detectSpeech(samples: samples, threshold: threshold, minSpeechSec: 0.2, minSilenceSec: 0.35, padSec: 0.08, normalizeQuietInput: false)
        if res.intervals.isEmpty {
            return ([], 0.0)
        }
        var out: [Float] = []
        out.reserveCapacity(Int(res.speechSeconds * Double(Self.sampleRate)) + 1024)
        for iv in res.intervals {
            let seg = AudioDecoder.slice(samples, startSec: iv.startSec, endSec: iv.endSec)
            out.append(contentsOf: seg)
        }
        return (out, Double(out.count) / Double(Self.sampleRate))
    }

    // MARK: - CoreML Inference

    private func runCoreMLProbabilities(model: MLModel, samples: [Float]) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let numWindows = samples.count / Self.windowSamples
        guard numWindows > 0 else { return [] }
        guard let inputArr = try? MLMultiArray(shape: [1, 576], dataType: .float32),
              let stateA = try? MLMultiArray(shape: [2, 1, 128], dataType: .float32),
              let stateB = try? MLMultiArray(shape: [2, 1, 128], dataType: .float32),
              let probBacking = try? MLMultiArray(shape: [1, 1], dataType: .float32),
              let providerA = try? MLDictionaryFeatureProvider(dictionary: [
                  "input_576": MLFeatureValue(multiArray: inputArr),
                  "vad_state": MLFeatureValue(multiArray: stateA)
              ]),
              let providerB = try? MLDictionaryFeatureProvider(dictionary: [
                  "input_576": MLFeatureValue(multiArray: inputArr),
                  "vad_state": MLFeatureValue(multiArray: stateB)
              ]) else {
            return runEnergyFallbackProbabilities(samples: samples)
        }
        // Zero initial LSTM state & 64-sample context; ping-pong outputBackings avoid 1875 allocs/min.
        stateA.dataPointer.bindMemory(to: Float.self, capacity: 256).initialize(repeating: 0, count: 256)
        stateB.dataPointer.bindMemory(to: Float.self, capacity: 256).initialize(repeating: 0, count: 256)
        let optsA = MLPredictionOptions()
        optsA.outputBackings = ["prob": probBacking, "next_state": stateB]
        let optsB = MLPredictionOptions()
        optsB.outputBackings = ["prob": probBacking, "next_state": stateA]

        var context = [Float](repeating: 0, count: Self.contextSamples)
        var probs = [Float](repeating: 0, count: numWindows)
        let inPtr = inputArr.dataPointer.bindMemory(to: Float.self, capacity: 576)
        let probPtr = probBacking.dataPointer.bindMemory(to: Float.self, capacity: 1)

        var useA = true
        for w in 0..<numWindows {
            let offset = w * Self.windowSamples
            context.withUnsafeBufferPointer { cBuf in
                inPtr.update(from: cBuf.baseAddress!, count: Self.contextSamples)
            }
            samples.withUnsafeBufferPointer { sBuf in
                (inPtr + Self.contextSamples).update(from: sBuf.baseAddress! + offset, count: Self.windowSamples)
                context.withUnsafeMutableBufferPointer { cDst in
                    cDst.baseAddress!.update(
                        from: sBuf.baseAddress! + offset + (Self.windowSamples - Self.contextSamples),
                        count: Self.contextSamples
                    )
                }
            }
            let ok = autoreleasepool { () -> Bool in
                guard let out = try? model.prediction(from: useA ? providerA : providerB, options: useA ? optsA : optsB) else {
                    return false
                }
                if let pArr = out.featureValue(for: "prob")?.multiArrayValue, pArr !== probBacking {
                    probs[w] = pArr[0].floatValue
                } else {
                    probs[w] = probPtr[0]
                }
                if let nextArr = out.featureValue(for: "next_state")?.multiArrayValue {
                    let expectedDst = useA ? stateB : stateA
                    if nextArr !== expectedDst {
                        memcpy(expectedDst.dataPointer, nextArr.dataPointer, 256 * MemoryLayout<Float>.size)
                    }
                }
                return true
            }
            if !ok { break }
            useA.toggle()
        }
        return probs
    }

    private func runEnergyFallbackProbabilities(samples: [Float]) -> [Float] {
        let numWindows = samples.count / Self.windowSamples
        guard numWindows > 0 else { return [] }
        var rmsValues = [Float](repeating: 0, count: numWindows)
        samples.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for w in 0..<numWindows {
                var msq: Float = 0
                vDSP_measqv(base + w * Self.windowSamples, 1, &msq, vDSP_Length(Self.windowSamples))
                rmsValues[w] = sqrt(max(msq, 0))
            }
        }
        let sorted = rmsValues.sorted()
        let noiseFloor = max(0.004, sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.2))])
        let speechRef = max(noiseFloor * 2.5, 0.015)
        return rmsValues.map { r in
            let norm = (r - noiseFloor) / max(speechRef - noiseFloor, 1e-4)
            return min(1.0, max(0.0, norm))
        }
    }

    private func hysteresisDecode(
        probs: [Float],
        durationSec: Double,
        threshold: Float,
        minSpeechSec: Double,
        minSilenceSec: Double,
        padSec: Double
    ) -> [SpeechInterval] {
        let frameSec = Double(Self.windowSamples) / Double(Self.sampleRate) // 0.032s
        let negThreshold = max(0.10, threshold - 0.15)
        let minSilenceFrames = max(1, Int((minSilenceSec / frameSec).rounded()))

        var raw: [(start: Double, end: Double)] = []
        var triggered = false
        var startIdx = 0
        var silenceCount = 0

        for (i, p) in probs.enumerated() {
            if !triggered {
                if p >= threshold {
                    triggered = true
                    startIdx = i
                    silenceCount = 0
                }
            } else {
                if p >= negThreshold {
                    silenceCount = 0
                } else {
                    silenceCount += 1
                    if silenceCount >= minSilenceFrames {
                        let endIdx = max(startIdx + 1, i - silenceCount + 1)
                        raw.append((Double(startIdx) * frameSec, Double(endIdx) * frameSec))
                        triggered = false
                        silenceCount = 0
                    }
                }
            }
        }
        if triggered {
            raw.append((Double(startIdx) * frameSec, min(durationSec, Double(probs.count) * frameSec)))
        }

        // Filter too-short segments, pad, and merge overlaps
        var merged: [SpeechInterval] = []
        for seg in raw where (seg.end - seg.start) >= minSpeechSec {
            let s = max(0.0, seg.start - padSec)
            let e = min(durationSec, seg.end + padSec)
            if let last = merged.last, s <= last.endSec + 0.05 {
                merged[merged.count - 1] = SpeechInterval(startSec: last.startSec, endSec: max(last.endSec, e))
            } else {
                merged.append(SpeechInterval(startSec: s, endSec: e))
            }
        }
        return merged
    }
}
