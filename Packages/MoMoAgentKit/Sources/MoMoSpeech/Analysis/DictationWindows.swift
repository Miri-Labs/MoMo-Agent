import Foundation

enum DictationWindows {
    static func make(_ detected: [Range<Int64>], sampleCount: Int, maximumFrames: Int, padding: Int) -> [Range<Int>] {
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
        return merged.flatMap { range in
            stride(from: range.lowerBound, to: range.upperBound, by: maximumFrames).map {
                $0..<min($0 + maximumFrames, range.upperBound)
            }
        }
    }
}
