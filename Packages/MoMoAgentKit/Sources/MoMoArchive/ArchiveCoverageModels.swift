import Foundation
import MoMoContracts

public struct RecordingCoverage: Sendable {
    public let sessionID: UUID
    /// Nil keeps receipt and mark data available while processing coverage is unknown.
    public let configurationFingerprint: String?
    public let epochs: [EpochCoverage]
    /// The Watch's last versioned observation, not current completeness or receipt evidence.
    public let watchCapturedDuration: TimeInterval?
    public let watchStatusUpdatedAt: Date?

    public var receivedDuration: TimeInterval { duration(\.received) }
    public var analyzedDuration: TimeInterval? { configurationFingerprint.map { _ in duration(\.analyzed) } }
    public var transcribedDuration: TimeInterval? { configurationFingerprint.map { _ in duration(\.transcribed) } }
    public var processedDuration: TimeInterval? { configurationFingerprint.map { _ in duration(\.processed) } }

    private func duration(_ key: KeyPath<EpochCoverage, [FrameRange]>) -> TimeInterval {
        epochs.reduce(0) { total, epoch in
            guard let rate = epoch.timebaseHz else { return total }
            return total + epoch[keyPath: key].reduce(0) { $0 + Double($1.count) / rate }
        }
    }
}

public struct EpochCoverage: Sendable, Identifiable {
    public var id: UUID { epochID }
    public let epochID: UUID
    /// Unknown when only a control event has arrived, without a manifest.
    public let timebaseHz: Double?
    public let closedAtFrame: Int64?
    public let observedThroughFrame: Int64
    /// An open epoch has an unbounded unknown tail, even when its received prefix is processed.
    public var unknownTailFromFrame: Int64? { closedAtFrame == nil ? observedThroughFrame : nil }
    /// Historically accepted complete audio. Retention does not erase receipt coverage.
    public let received: [FrameRange]
    public let analyzed: [FrameRange]
    /// Completed recognition cores, including recognition that returned no text.
    public let transcribed: [FrameRange]
    public let noSpeech: [FrameRange]
    /// The union of completed recognition and explicit no-speech analysis.
    public let processed: [FrameRange]
    /// Absent receipt coverage inside the known prefix. Its cause is not inferred.
    public let notReceived: [FrameRange]
    public let pendingAnalysis: [FrameRange]
    public let pendingTranscription: [FrameRange]
    /// Unfinished received ranges, excluding recorded failures and unavailable originals.
    public let pending: [FrameRange]
    public let failed: [FrameRange]
    public let unavailableAudio: [FrameRange]
    public let failures: [CoverageFailure]
    public let marks: [ArchiveMarkCoverage]
}

public struct CoverageFailure: Sendable {
    public let chunkID: UUID
    public let frames: FrameRange
    public let errorCode: String?
}

public enum MarkCoverageLocation: String, Sendable {
    case received, notReceived, unknownTail, epochEnd
}

public struct ArchiveMarkCoverage: Sendable, Identifiable {
    public var id: UUID { mark.markID }
    public let mark: CaptureMark
    public let location: MarkCoverageLocation
    public let chunkIDs: [UUID]
    public let sources: [SourceReference]
}
