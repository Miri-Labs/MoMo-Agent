import Foundation
import MoMoContracts

public enum TranscriptionBatchState: String, Codable, Sendable { case ready, running, paused, completed }
public enum TranscriptionBatchOrigin: String, Codable, Sendable { case foreground, backgroundProcessing, continuedProcessing }
public enum TranscriptionBatchEndReason: String, Codable, Sendable {
    case completed, userPaused, systemEndedUnknown, backgroundExpired, interrupted
}
public enum TranscriptionBatchError: Error, Equatable, Sendable {
    case missingBatch(UUID), paused, staleExecution, incomplete, configurationMismatch
}

public struct TranscriptionBatchExecution: Codable, Equatable, Sendable {
    public let batchID: UUID
    public let executionID: UUID
    public let origin: TranscriptionBatchOrigin
}

/// Frames from different epochs are never merged; each epoch retains its source timebase.
public struct TranscriptionBatchCoverage: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let epochID: UUID
    public let timebaseHz: Double
    public let frozen: [FrameRange]
    public let noSpeech: [FrameRange]
    public let completed: [FrameRange]
    public let removed: [FrameRange]
}

public struct TranscriptionBatch: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let configurationFingerprint: String
    public let state: TranscriptionBatchState
    public let endReason: TranscriptionBatchEndReason?
    public let execution: TranscriptionBatchExecution?
    public let windowIDs: [String]
    public let coverage: [TranscriptionBatchCoverage]
    public var totalDuration: TimeInterval { coverage.reduce(0) { $0 + duration($1.frozen, at: $1.timebaseHz) } }
    public var completedDuration: TimeInterval { coverage.reduce(0) { $0 + duration($1.completed, at: $1.timebaseHz) } }
    public var removedDuration: TimeInterval { coverage.reduce(0) { $0 + duration($1.removed, at: $1.timebaseHz) } }

    private func duration(_ ranges: [FrameRange], at rate: Double) -> Double {
        ranges.reduce(0) { $0 + Double($1.count) / rate }
    }
}
