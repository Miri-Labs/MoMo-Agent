import Accelerate
import Foundation

/// Exact `lab260/redimnet2-plus` `SpectralFeaturesTF` (`TFMelBanks`) frontend in Accelerate vDSP:
///   1. PreEmphasis(coef = 0.97) with reflect left pad of 1 sample: y[0] = x[0] - 0.97*x[1], y[i] = x[i] - 0.97*x[i-1]
///   2. Zero pad by 80 samples on both sides (F.conv1d padding=80, kernel=400, stride=160)
///   3. 400-point Hamming windowed 512-point DFT -> 256 frequency bins (0..255) power spectrum
///   4. Multiply by `mel_filterbank_72x256.bin` [72, 256]
///   5. log(x + 1e-8)
///   6. Per-frequency-bin mean subtraction over time axis
/// Output shape: [72, T] row-major Float32, padded/cropped/tiled to static bucket T in {200, 400, 600}.
public final class ReDimNetMelFrontend: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let preEmphasis: Float = 0.97
    public static let frameLength = 400
    public static let frameStep = 160
    public static let fftLength = 512
    public static let numFreqBins = 256
    public static let numMels = 72
    public static let padSize = 80
    public static let eps: Float = 1e-8
    public static let supportedBuckets = [200, 400, 600]

    private let melFilterbank: [Float] // [72, 256]
    private let dftCos: [Float]        // [256, 400] (Hamming-windowed)
    private let dftSin: [Float]        // [256, 400] (Hamming-windowed)

    public init(melFilterbankURL: URL, windowURL: URL) throws {
        let melData = try Data(contentsOf: melFilterbankURL)
        let expectedMelBytes = Self.numMels * Self.numFreqBins * MemoryLayout<Float>.size
        guard melData.count == expectedMelBytes else {
            throw SpeechEngineError.invalidBundle("ReDimNet mel filterbank size mismatch: \(melData.count)")
        }
        self.melFilterbank = melData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let winData = try Data(contentsOf: windowURL)
        let expectedWinBytes = Self.frameLength * MemoryLayout<Float>.size
        guard winData.count == expectedWinBytes else {
            throw SpeechEngineError.invalidBundle("ReDimNet hamming window size mismatch: \(winData.count)")
        }
        let win = winData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        var cosMat = [Float](repeating: 0, count: Self.numFreqBins * Self.frameLength)
        var sinMat = [Float](repeating: 0, count: Self.numFreqBins * Self.frameLength)
        let twoPiOverFFT = 2.0 * Double.pi / Double(Self.fftLength)
        for k in 0..<Self.numFreqBins {
            let rowOff = k * Self.frameLength
            let kf = Double(k)
            for n in 0..<Self.frameLength {
                let angle = twoPiOverFFT * kf * Double(n)
                let w = Double(win[n])
                cosMat[rowOff + n] = Float(w * cos(angle))
                sinMat[rowOff + n] = Float(-w * sin(angle))
            }
        }
        self.dftCos = cosMat
        self.dftSin = sinMat
    }

    /// Selects the optimal static CoreML bucket (200=2s, 400=4s, 600=6s) for a clean audio clip.
    public static func selectBucket(forSampleCount sampleCount: Int) -> Int {
        let seconds = Double(sampleCount) / Double(sampleRate)
        if seconds < 3.0 { return 200 }
        if seconds < 5.0 { return 400 }
        return 600
    }

    /// Prepares audio (center crop if longer than target bucket, repeat-tile if slightly shorter)
    /// and extracts exact [72, bucketFrames] row-major Float32 mel features.
    public func extractForBucket(_ samples: [Float], bucketFrames: Int) -> [Float] {
        // Exact number of samples that yields `bucketFrames` with conv1d(kernel=400, stride=160, pad=80):
        // out_frames = (N + 160 - 400) / 160 + 1 = (N - 240) / 160 + 1
        // => N = (bucketFrames - 1) * 160 + 240
        let targetSamples = (bucketFrames - 1) * Self.frameStep + (Self.frameLength - 2 * Self.padSize)
        var prepared = [Float](repeating: 0, count: targetSamples)
        if samples.count >= targetSamples {
            let start = (samples.count - targetSamples) / 2
            samples.withUnsafeBufferPointer { src in
                prepared.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress! + start, count: targetSamples)
                }
            }
        } else if !samples.isEmpty {
            var written = 0
            while written < targetSamples {
                let take = min(samples.count, targetSamples - written)
                samples.withUnsafeBufferPointer { src in
                    prepared.withUnsafeMutableBufferPointer { dst in
                        (dst.baseAddress! + written).update(from: src.baseAddress!, count: take)
                    }
                }
                written += take
            }
        }
        let (mel, numFrames) = extractRaw(prepared)
        if numFrames == bucketFrames {
            return mel
        }
        // Adjust frame count safely if rounding differs by 1 frame
        var out = [Float](repeating: 0, count: Self.numMels * bucketFrames)
        let copyT = min(numFrames, bucketFrames)
        for m in 0..<Self.numMels {
            let srcOff = m * numFrames
            let dstOff = m * bucketFrames
            for t in 0..<copyT {
                out[dstOff + t] = mel[srcOff + t]
            }
        }
        return out
    }

    /// Extracts unbucketed exact [72, T] mel features matching `TFMelBanks.forward`.
    public func extractRaw(_ samples: [Float]) -> (mel: [Float], frames: Int) {
        let N = samples.count
        guard N >= 2 else { return ([], 0) }

        // 1. PreEmphasis(0.97) with PyTorch F.pad(x, (1, 0), mode='reflect'):
        //    padded_x = [x[1], x[0], x[1], ..., x[N-1]]
        //    out[i] = padded_x[i+1] - 0.97 * padded_x[i]
        var pre = [Float](repeating: 0, count: N)
        pre[0] = samples[0] - Self.preEmphasis * samples[1]
        for i in 1..<N {
            pre[i] = samples[i] - Self.preEmphasis * samples[i - 1]
        }

        // 2. Zero pad by 80 on both sides
        let paddedLen = N + 2 * Self.padSize
        guard paddedLen >= Self.frameLength else { return ([], 0) }
        var padded = [Float](repeating: 0, count: paddedLen)
        padded.withUnsafeMutableBufferPointer { dst in
            pre.withUnsafeBufferPointer { src in
                (dst.baseAddress! + Self.padSize).update(from: src.baseAddress!, count: N)
            }
        }

        let T = (paddedLen - Self.frameLength) / Self.frameStep + 1
        let L = Self.frameLength
        let K = Self.numFreqBins

        var frames = [Float](repeating: 0, count: T * L)
        padded.withUnsafeBufferPointer { pBuf in
            frames.withUnsafeMutableBufferPointer { fBuf in
                let pBase = pBuf.baseAddress!
                let fBase = fBuf.baseAddress!
                for t in 0..<T {
                    (fBase + t * L).update(from: pBase + t * Self.frameStep, count: L)
                }
            }
        }

        // 3. STFT real/imag [256, T] = dft [256, 400] * frames^T [400, T]
        var realSpec = [Float](repeating: 0, count: K * T)
        var imagSpec = [Float](repeating: 0, count: K * T)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(K), Int32(T), Int32(L),
            1.0, dftCos, Int32(L),
            frames, Int32(L),
            0.0, &realSpec, Int32(T)
        )
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(K), Int32(T), Int32(L),
            1.0, dftSin, Int32(L),
            frames, Int32(L),
            0.0, &imagSpec, Int32(T)
        )

        // Power = real^2 + imag^2
        let specLen = vDSP_Length(K * T)
        vDSP_vsq(realSpec, 1, &realSpec, 1, specLen)
        vDSP_vsq(imagSpec, 1, &imagSpec, 1, specLen)
        vDSP_vadd(realSpec, 1, imagSpec, 1, &realSpec, 1, specLen)

        // 4. Mel [72, T] = melFilterbank [72, 256] * power [256, T]
        var mel = [Float](repeating: 0, count: Self.numMels * T)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasNoTrans,
            Int32(Self.numMels), Int32(T), Int32(K),
            1.0, melFilterbank, Int32(K),
            realSpec, Int32(T),
            0.0, &mel, Int32(T)
        )

        // 5. log(x + 1e-8)
        let total = Self.numMels * T
        var epsVal = Self.eps
        vDSP_vsadd(mel, 1, &epsVal, &mel, 1, vDSP_Length(total))
        var total32 = Int32(total)
        vvlogf(&mel, mel, &total32)

        // 6. Per-bin mean subtraction over time axis
        for m in 0..<Self.numMels {
            let off = m * T
            var mean: Float = 0
            mel.withUnsafeBufferPointer { buf in
                vDSP_meanv(buf.baseAddress! + off, 1, &mean, vDSP_Length(T))
            }
            var negMean = -mean
            mel.withUnsafeMutableBufferPointer { buf in
                vDSP_vsadd(buf.baseAddress! + off, 1, &negMean, buf.baseAddress! + off, 1, vDSP_Length(T))
            }
        }

        return (mel, T)
    }
}
