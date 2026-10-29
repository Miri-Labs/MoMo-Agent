import Foundation
import MoMoContracts

public struct ArchivedAudioInput: Sendable {
    public let envelope: ManifestEnvelope
    public let audioURL: URL
}

public struct ArchiveCheckpoint: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let epochID: UUID
    public let sourceFrame: Int64
    public let configurationFingerprint: String
    public init(sessionID: UUID, epochID: UUID, sourceFrame: Int64, configurationFingerprint: String) {
        self.sessionID = sessionID; self.epochID = epochID; self.sourceFrame = sourceFrame
        self.configurationFingerprint = configurationFingerprint
    }
}

public struct ArchiveWindowSource: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let manifestSHA256: String
    public let audioSHA256: String
    public let sourceFrames: FrameRange
    public init(chunkID: UUID, manifestSHA256: String, audioSHA256: String, sourceFrames: FrameRange) {
        self.chunkID = chunkID; self.manifestSHA256 = manifestSHA256
        self.audioSHA256 = audioSHA256; self.sourceFrames = sourceFrames
    }
}

public struct ArchiveAnalysisWindow: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: UUID
    public let epochID: UUID
    public let analysisAnchor: Int64
    public let coreFrames: FrameRange
    public let contextFrames: FrameRange
    public let modelCoreFrames: FrameRange
    public let modelContextFrames: FrameRange
    public let sources: [ArchiveWindowSource]
    public let replayInputManifestHashes: [String]
    public let configurationFingerprint: String
    public init(id: String, sessionID: UUID, epochID: UUID, analysisAnchor: Int64, coreFrames: FrameRange,
                contextFrames: FrameRange, modelCoreFrames: FrameRange, modelContextFrames: FrameRange,
                sources: [ArchiveWindowSource], replayInputManifestHashes: [String]? = nil, configurationFingerprint: String) {
        self.id = id; self.sessionID = sessionID; self.epochID = epochID; self.analysisAnchor = analysisAnchor
        self.coreFrames = coreFrames; self.contextFrames = contextFrames
        self.modelCoreFrames = modelCoreFrames; self.modelContextFrames = modelContextFrames
        self.sources = sources; self.replayInputManifestHashes = replayInputManifestHashes ?? sources.map(\.manifestSHA256)
        self.configurationFingerprint = configurationFingerprint
    }
}

public struct EpochAnalysisTicket: Sendable {
    public let attemptID: UUID
    public let sessionID: UUID
    public let epochID: UUID
    public let expectedGeneration: Int64
    public let inputs: [ArchivedAudioInput]
    public let checkpoint: ArchiveCheckpoint?
    /// Present only when the ticket also leases the retained prefix needed to rebuild VAD state.
    public let replayOrigin: Int64?
    public let boundary: AudioProcessingBoundary
    /// Compatibility for callers using the old snapshot-finalization flag.
    public var epochClosed: Bool { boundary.endFrame != nil }
    public let configurationFingerprint: String
    let inputIdentity: String
    let leaseIDs: [UUID]
}

public struct TranscriptionWindowTicket: Sendable {
    public let attemptID: UUID
    public let window: ArchiveAnalysisWindow
    public let inputs: [ArchivedAudioInput]
    public let expectedGeneration: Int64
    public let batchExecution: TranscriptionBatchExecution?
    let leaseIDs: [UUID]
}

public struct TranscriptAudioRange: Codable, Equatable, Sendable {
    public let chunkID: UUID
    public let frames: FrameRange
    public init(chunkID: UUID, frames: FrameRange) { self.chunkID = chunkID; self.frames = frames }
}

public struct AudioPlaybackPart: Sendable {
    public let lease: AudioLease
    public let frames: FrameRange
}
