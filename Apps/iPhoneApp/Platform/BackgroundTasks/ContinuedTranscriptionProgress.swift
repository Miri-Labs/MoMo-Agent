import Foundation
import MoMoArchive

/// Report durable coverage of the whole batch; time spent running is not completed work.
enum ContinuedTranscriptionProgress {
    static let totalUnits: Int64 = 1_000_000

    static func completedUnits(batch: TranscriptionBatch, previous: Int64) -> Int64 {
        guard batch.state != .completed else { return totalUnits }
        let total = max(1, batch.totalDuration)
        let prepared = min(total, batch.preparedDuration + batch.removedDuration)
        let completed = min(total, batch.completedDuration + batch.removedDuration)
        let fraction = (prepared * 0.15 + completed * 0.85) / total
        let units = Int64((fraction * Double(totalUnits)).rounded(.down))
        return min(totalUnits - 1, max(previous, units))
    }
}
