import Accelerate
import Foundation

/// Exact Hugging Face `WhisperFeatureExtractor` frontend in Accelerate vDSP:
///   - 16 kHz mono float32 padded/trimmed to 480,000 samples (30s)
///   - Reflect padding of 200 samples on both sides (center=True, n_fft=400, hop_length=160)
///   - Periodic Hann window of length 400
///   - Power spectrum |STFT|^2 (201 bins) using 400-point exact DFT matrix (fast BLAS SGEMM)
///   - Multiply by Whisper mel filterbank [80, 201]
///   - log10(max(x, 1e-10)), clamp to >= max - 8.0, then (x + 4.0) / 4.0
/// Output shape: [80, 3000] row-major Float32.
public final class WhisperMelFrontend: @unchecked Sendable {
    public static let sampleRate = 16_000
    public static let chunkSamples = 480_000
    public static let nFFT = 400
    public static let hopLength = 160
    public static let numMels = 80
    public static let numFreqBins = 201
    public static let numFrames = 3_000

    private let melFilters: [Float] // [80, 201] row-major
    private let dftCos: [Float]     // [201, 400] row-major (windowed)
    private let dftSin: [Float]     // [201, 400] row-major (windowed)

    public init(melFiltersURL: URL) throws {
        let data = try Data(contentsOf: melFiltersURL)
        let expectedBytes = Self.numMels * Self.numFreqBins * MemoryLayout<Float>.size
        guard data.count == expectedBytes else {
            throw SpeechEngineError.invalidBundle("whisper_mel_filters size mismatch: \(data.count) != \(expectedBytes)")
        }
        self.melFilters = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }

        // Precompute periodic Hann window * DFT basis for exact 400-pt STFT (matches torch.stft(n_fft=400))
        var win = [Double](repeating: 0, count: Self.nFFT)
        for n in 0..<Self.nFFT {
            win[n] = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(n) / Double(Self.nFFT))
        }
        var cosMat = [Float](repeating: 0, count: Self.numFreqBins * Self.nFFT)
        var sinMat = [Float](repeating: 0, count: Self.numFreqBins * Self.nFFT)
        let twoPiOverN = 2.0 * Double.pi / Double(Self.nFFT)
        for k in 0..<Self.numFreqBins {
            let rowOff = k * Self.nFFT
            let kf = Double(k)
            for n in 0..<Self.nFFT {
                let angle = twoPiOverN * kf * Double(n)
                let w = win[n]
                cosMat[rowOff + n] = Float(w * cos(angle))
                sinMat[rowOff + n] = Float(-w * sin(angle))
            }
        }
        self.dftCos = cosMat
        self.dftSin = sinMat
    }

    /// Computes [80, 3000] row-major Whisper log-mel spectrogram for a <= 30s audio chunk.
    public func extractChunk(_ samples: ArraySlice<Float>) -> [Float] {
        // 1. Pad or trim to 480,000 samples
        var wav = [Float](repeating: 0, count: Self.chunkSamples)
        let copyCount = min(samples.count, Self.chunkSamples)
        if copyCount > 0 {
            samples.withUnsafeBufferPointer { src in
                wav.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: src.baseAddress!, count: copyCount)
                }
            }
        }

        // 2. Reflect pad by 200 samples on both sides -> 480,400 samples
        let pad = Self.nFFT / 2 // 200
        let paddedLen = Self.chunkSamples + 2 * pad
        var padded = [Float](repeating: 0, count: paddedLen)
        // Left reflect: padded[0..199] = wav[200], wav[199], ..., wav[1]
        for i in 0..<pad {
            padded[i] = wav[pad - i]
        }
        // Center
        padded.withUnsafeMutableBufferPointer { dst in
            wav.withUnsafeBufferPointer { src in
                (dst.baseAddress! + pad).update(from: src.baseAddress!, count: Self.chunkSamples)
            }
        }
        // Right reflect: padded[pad + N + i] = wav[N - 2 - i]
        for i in 0..<pad {
            padded[pad + Self.chunkSamples + i] = wav[Self.chunkSamples - 2 - i]
        }

        // 3. Build frame matrix X: [400, 3000] column-major = [3000, 400] row-major
        // Note: Whisper drops the last frame (3001 -> 3000).
        let F = Self.numFrames
        let N = Self.nFFT
        let K = Self.numFreqBins
        var frames = [Float](repeating: 0, count: F * N)
        padded.withUnsafeBufferPointer { pBuf in
            frames.withUnsafeMutableBufferPointer { fBuf in
                let pBase = pBuf.baseAddress!
                let fBase = fBuf.baseAddress!
                for t in 0..<F {
                    (fBase + t * N).update(from: pBase + t * Self.hopLength, count: N)
                }
            }
        }

        // 4. Real & Imag STFT via Accelerate vDSP_mmul:
        //    framesT [N, F] = transpose(frames [F, N])
        //    real [K, F] = dftCos [K, N] * framesT [N, F]
        //    imag [K, F] = dftSin [K, N] * framesT [N, F]
        var framesT = [Float](repeating: 0, count: N * F)
        vDSP_mtrans(frames, 1, &framesT, 1, vDSP_Length(N), vDSP_Length(F))
        var realSpec = [Float](repeating: 0, count: K * F)
        var imagSpec = [Float](repeating: 0, count: K * F)
        vDSP_mmul(dftCos, 1, framesT, 1, &realSpec, 1, vDSP_Length(K), vDSP_Length(F), vDSP_Length(N))
        vDSP_mmul(dftSin, 1, framesT, 1, &imagSpec, 1, vDSP_Length(K), vDSP_Length(F), vDSP_Length(N))

        // Power spectrum = real^2 + imag^2 -> stored in realSpec
        let specCount = vDSP_Length(K * F)
        vDSP_vsq(realSpec, 1, &realSpec, 1, specCount)
        vDSP_vsq(imagSpec, 1, &imagSpec, 1, specCount)
        vDSP_vadd(realSpec, 1, imagSpec, 1, &realSpec, 1, specCount)

        // 5. Mel projection: melSpec [80, 3000] = melFilters [80, 201] * powerSpec [201, 3000]
        var melSpec = [Float](repeating: 0, count: Self.numMels * F)
        vDSP_mmul(melFilters, 1, realSpec, 1, &melSpec, 1, vDSP_Length(Self.numMels), vDSP_Length(F), vDSP_Length(K))

        // 6. Log10 scaling & Whisper normalization
        let total = Self.numMels * F
        var floorVal: Float = 1e-10
        vDSP_vthr(melSpec, 1, &floorVal, &melSpec, 1, vDSP_Length(total))
        var count32 = Int32(total)
        vvlog10f(&melSpec, melSpec, &count32)

        var maxVal: Float = -Float.greatestFiniteMagnitude
        vDSP_maxv(melSpec, 1, &maxVal, vDSP_Length(total))
        var minClamp = maxVal - 8.0
        vDSP_vthr(melSpec, 1, &minClamp, &melSpec, 1, vDSP_Length(total))

        // (x + 4.0) / 4.0
        var addFour: Float = 4.0
        var invFour: Float = 0.25
        vDSP_vsadd(melSpec, 1, &addFour, &melSpec, 1, vDSP_Length(total))
        vDSP_vsmul(melSpec, 1, &invFour, &melSpec, 1, vDSP_Length(total))
        return melSpec
    }
}
