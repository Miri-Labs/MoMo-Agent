import Foundation

enum DictationWindows {
    static func make(_ detected: [Range<Int64>], sampleCount: Int, maximumFrames: Int, padding: Int,
                     model: SpeechModelChoice = .senseVoice) -> [Range<Int>] {
        guard sampleCount > 0, maximumFrames > 0 else { return [] }
        var merged: [Range<Int>] = []
        for range in detected.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(0, min(sampleCount, Int(clamping: range.lowerBound)) - padding)
            let end = min(sampleCount, min(sampleCount, Int(clamping: range.upperBound)) + padding)
            guard start < end else { continue }
            if let last = merged.last, start <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(end, last.upperBound)
            } else { merged.append(start..<end) }
        }
        // Partition without overlapping text; VAD padding is only applied at utterance boundaries.
        let windows = merged.flatMap { range in
            stride(from: range.lowerBound, to: range.upperBound, by: maximumFrames).map {
                $0..<min($0 + maximumFrames, range.upperBound)
            }
        }
        guard model == .xASR else { return windows }
        // X-ASR benefits from hearing both sides of a brief pause. The two facing
        // collars already cover part of that pause. Join only complete, bounded
        // windows so the join cannot create a new cut through speech.
        let maximumGap = max(0, SpeechConfiguration.sampleRate - 2 * padding)
        var joined: [Range<Int>] = []
        for window in windows {
            if let previous = joined.last, window.lowerBound - previous.upperBound <= maximumGap,
               window.upperBound - previous.lowerBound <= maximumFrames {
                joined[joined.count - 1] = previous.lowerBound..<window.upperBound
            } else {
                joined.append(window)
            }
        }
        return joined
    }
}
