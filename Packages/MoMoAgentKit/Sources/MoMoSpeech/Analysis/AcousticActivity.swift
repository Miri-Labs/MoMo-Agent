import Foundation
import MoMoAcousticVAD

/// Cheap acoustic evidence for ranges Silero may reject. It never replaces Silero's utterance boundaries.
final class AcousticActivity {
    private let pointer: OpaquePointer
    private var frame = [Int16](repeating: 0, count: 320)
    private var filled = 0
    private var accepted: Int64 = 0
    private var judged: Int64 = 0
    private var blockStart: Int64 = 0
    private var voiced: Int64 = 0
    private var consecutiveVoiced: Int64 = 0
    private var longestVoiced: Int64 = 0
    private var completed: [Range<Int64>] = []
    private static let blockFrames: Int64 = 20 * 16_000

    init() throws {
        guard let created = fvad_new() else { throw SpeechError.nativeInitialization }
        guard fvad_set_sample_rate(created, 16_000) == 0, fvad_set_mode(created, 0) == 0 else {
            fvad_free(created)
            throw SpeechError.nativeInitialization
        }
        pointer = created
    }

    deinit { fvad_free(pointer) }

    func reset() {
        fvad_reset(pointer)
        precondition(fvad_set_sample_rate(pointer, 16_000) == 0 && fvad_set_mode(pointer, 0) == 0)
        filled = 0; accepted = 0; judged = 0; blockStart = 0; voiced = 0
        consecutiveVoiced = 0; longestVoiced = 0
        completed.removeAll(keepingCapacity: true)
    }

    func accept(_ samples: [Float]) throws {
        for sample in samples {
            guard sample.isFinite else { throw SpeechError.invalidAudio("non_finite_sample") }
            frame[filled] = Int16(max(-32_768, min(32_767, (sample * 32_768).rounded())))
            filled += 1; accepted += 1
            if filled == frame.count {
                let decision = frame.withUnsafeBufferPointer { fvad_process(pointer, $0.baseAddress, $0.count) }
                guard decision >= 0 else { throw SpeechError.nativeResult }
                if decision == 1 {
                    voiced += Int64(frame.count)
                    consecutiveVoiced += Int64(frame.count)
                    longestVoiced = max(longestVoiced, consecutiveVoiced)
                } else { consecutiveVoiced = 0 }
                judged += Int64(frame.count)
                filled = 0
                if judged - blockStart == Self.blockFrames {
                    if let range = candidate(through: judged) { completed.append(range) }
                    blockStart = judged; voiced = 0; longestVoiced = 0
                }
            }
        }
    }

    func drain(includePartial: Bool) -> [Range<Int64>] {
        var result = completed
        completed.removeAll(keepingCapacity: true)
        if includePartial, let range = candidate(through: accepted) { result.append(range) }
        return result
    }

    private func candidate(through end: Int64) -> Range<Int64>? {
        // Keep short replies even when they occupy little of a 20s range.
        // Otherwise require 5% cumulative evidence, with a 100ms floor for short tails.
        guard end > blockStart,
              longestVoiced >= 3_200 || voiced >= max(1_600, (end - blockStart + 19) / 20) else { return nil }
        return blockStart..<end
    }
}
