import Accelerate
import AVFoundation
import Foundation

public enum SpeechEngineError: Error, LocalizedError, Sendable {
    case invalidBundle(String)
    case audioDecodeFailed(String)
    case inferenceFailed(String)
    case audioTooShort(Double)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBundle(let m): return "Invalid CoreML speech bundle: \(m)"
        case .audioDecodeFailed(let m): return "Audio decode failed: \(m)"
        case .inferenceFailed(let m): return "CoreML inference failed: \(m)"
        case .audioTooShort(let sec): return String(format: "Audio too short: %.2fs", sec)
        case .invalidRequest(let m): return "Invalid request: \(m)"
        }
    }
}

public struct DecodedAudio: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public var durationSeconds: Double {
        Double(samples.count) / Double(sampleRate)
    }
}

public struct AudioChunkSpan: Sendable {
    public let path: String
    public let startSample: Int
    public let sampleCount: Int
}

/// Native macOS audio decoder (`AVAudioFile` + `AVAudioConverter`) producing 16 kHz mono Float32 PCM.
public enum AudioDecoder {
    public static let targetSampleRate: Double = 16_000.0

    public static func decodeFile(at url: URL) throws -> DecodedAudio {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpeechEngineError.audioDecodeFailed("File not found: \(url.path)")
        }
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw SpeechEngineError.audioDecodeFailed("Cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }

        let srcFormat = audioFile.processingFormat
        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechEngineError.audioDecodeFailed("Cannot create 16 kHz mono float32 format")
        }

        // Fast path when already 16 kHz mono float32
        if abs(srcFormat.sampleRate - targetSampleRate) < 0.5 &&
            srcFormat.channelCount == 1 &&
            srcFormat.commonFormat == .pcmFormatFloat32 {
            let totalFrames = AVAudioFrameCount(max(0, audioFile.length))
            var samples: [Float] = []
            samples.reserveCapacity(Int(totalFrames))
            let chunkFrames: AVAudioFrameCount = 32_768
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
                throw SpeechEngineError.audioDecodeFailed("Failed to allocate PCM buffer")
            }
            while audioFile.framePosition < audioFile.length {
                let remaining = AVAudioFrameCount(min(Int64(chunkFrames), audioFile.length - audioFile.framePosition))
                if remaining == 0 { break }
                buf.frameLength = 0
                do {
                    try audioFile.read(into: buf, frameCount: remaining)
                } catch {
                    throw SpeechEngineError.audioDecodeFailed("Read failed: \(error.localizedDescription)")
                }
                if buf.frameLength == 0 { break }
                if let ch = buf.floatChannelData?[0] {
                    samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
                }
            }
            return DecodedAudio(samples: samples, sampleRate: Int(targetSampleRate))
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw SpeechEngineError.audioDecodeFailed("Cannot create AVAudioConverter from \(srcFormat) to 16k mono")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue

        let inputChunkFrames: AVAudioFrameCount = 16_384
        let ratio = targetSampleRate / max(srcFormat.sampleRate, 1.0)
        let outputChunkFrames = AVAudioFrameCount(max(1024, Int(ceil(Double(inputChunkFrames) * ratio)) + 512))
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: inputChunkFrames),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputChunkFrames) else {
            throw SpeechEngineError.audioDecodeFailed("Failed to allocate converter buffers")
        }

        var samples: [Float] = []
        let estSamples = Int(ceil(Double(audioFile.length) * ratio))
        if estSamples > 0 { samples.reserveCapacity(estSamples) }

        var reachedEOF = false
        var readError: Error?

        while true {
            outBuf.frameLength = 0
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                if reachedEOF || audioFile.framePosition >= audioFile.length {
                    reachedEOF = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                let remaining = AVAudioFrameCount(min(Int64(inputChunkFrames), audioFile.length - audioFile.framePosition))
                if remaining == 0 {
                    reachedEOF = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inBuf.frameLength = 0
                do {
                    try audioFile.read(into: inBuf, frameCount: remaining)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    reachedEOF = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            if let readError {
                throw SpeechEngineError.audioDecodeFailed("Audio read error: \(readError.localizedDescription)")
            }
            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream { break }
            if status == .error {
                throw SpeechEngineError.audioDecodeFailed(convErr?.localizedDescription ?? "Converter error")
            }
        }
        return DecodedAudio(samples: samples, sampleRate: Int(targetSampleRate))
    }

    public static func decodeConcatenated(urls: [URL]) throws -> (audio: DecodedAudio, spans: [AudioChunkSpan]) {
        var allSamples: [Float] = []
        var spans: [AudioChunkSpan] = []
        for url in urls {
            let decoded = try decodeFile(at: url)
            let start = allSamples.count
            allSamples.append(contentsOf: decoded.samples)
            spans.append(AudioChunkSpan(path: url.path, startSample: start, sampleCount: decoded.samples.count))
        }
        return (DecodedAudio(samples: allSamples, sampleRate: Int(targetSampleRate)), spans)
    }

    /// Slices `[startSec, endSec]` from 16 kHz mono PCM safely clamped to bounds.
    public static func slice(_ samples: [Float], startSec: Double, endSec: Double, sampleRate: Int = 16_000) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let s = max(0, min(samples.count, Int((startSec * Double(sampleRate)).rounded())))
        let e = max(s, min(samples.count, Int((endSec * Double(sampleRate)).rounded())))
        if e <= s { return [] }
        return Array(samples[s..<e])
    }

    /// Computes signal RMS and estimated speech SNR (dB) using 20ms frame energy percentiles (P90 vs P15).
    public static func computeSignalStats(_ samples: [Float], sampleRate: Int = 16_000) -> (rmsDb: Double, snrDb: Double) {
        guard samples.count >= 320 else { return (-90.0, 0.0) }
        var meanSq: Float = 0
        vDSP_measqv(samples, 1, &meanSq, vDSP_Length(samples.count))
        let rms = sqrt(max(Double(meanSq), 1e-12))
        let rmsDb = 20.0 * log10(rms)

        let frameSize = sampleRate / 50 // 20ms = 320 samples
        let frameCount = samples.count / frameSize
        guard frameCount >= 4 else { return (rmsDb, 0.0) }
        var frameDb = [Double](repeating: -90.0, count: frameCount)
        samples.withUnsafeBufferPointer { buf in
            let base = buf.baseAddress!
            for i in 0..<frameCount {
                var msq: Float = 0
                vDSP_measqv(base + i * frameSize, 1, &msq, vDSP_Length(frameSize))
                frameDb[i] = 10.0 * log10(max(Double(msq), 1e-12))
            }
        }
        frameDb.sort()
        let p15 = frameDb[min(frameCount - 1, Int(Double(frameCount) * 0.15))]
        let p90 = frameDb[min(frameCount - 1, Int(Double(frameCount) * 0.90))]
        return (rmsDb, max(0.0, p90 - p15))
    }

    /// Applies gentle P98 peak normalization for quiet Apple Watch recordings before VAD/ASR.
    /// Does not amplify pure silence (noise floor <= -50 dBFS).
    public static func applyGentleGainNormalization(_ samples: [Float], targetP98: Float = 0.25, maxGainDb: Double = 18.0) -> [Float] {
        guard samples.count >= 160 else { return samples }
        var absSamples = [Float](repeating: 0, count: samples.count)
        vDSP_vabs(samples, 1, &absSamples, 1, vDSP_Length(samples.count))
        // Sample up to 4000 evenly spaced points for fast P98 estimate
        let stride = max(1, absSamples.count / 4000)
        var sub: [Float] = []
        sub.reserveCapacity(absSamples.count / stride + 1)
        var i = 0
        while i < absSamples.count {
            sub.append(absSamples[i])
            i += stride
        }
        sub.sort()
        let p98 = sub[min(sub.count - 1, Int(Double(sub.count) * 0.98))]
        if p98 < 0.003 || p98 >= targetP98 {
            return samples
        }
        let maxLinearGain = Float(pow(10.0, maxGainDb / 20.0))
        let gain = min(maxLinearGain, targetP98 / p98)
        if gain <= 1.05 { return samples }
        var out = [Float](repeating: 0, count: samples.count)
        var g = gain
        vDSP_vsmul(samples, 1, &g, &out, 1, vDSP_Length(samples.count))
        var lo: Float = -0.99
        var hi: Float = 0.99
        vDSP_vclip(out, 1, &lo, &hi, &out, 1, vDSP_Length(out.count))
        return out
    }
}
