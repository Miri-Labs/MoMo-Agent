import Foundation
import MoMoContracts

public enum RecordingFileIssueKind: String, Sendable, Codable {
    case missingDirectory, missingFiles, conflictingEdits, invalidEdit
    case ambiguousLocation, unsafePath, audioMismatch, readFailure
}

public enum RecordingFileRecoveryAction: String, Sendable, Codable {
    case restoreDatabase, useJSON, useMarkdown, deleteRecording
}

/// A confirmation snapshot. An operation is rejected if the files or source version have changed.
public struct RecordingFileIssue: Identifiable, Sendable, Equatable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let kind: RecordingFileIssueKind
    public let relativeDirectory: String
    public let candidateDirectories: [String]
    public let missingFiles: [String]
    public let availableActions: [RecordingFileRecoveryAction]
    public let fingerprint: String
    public let transcriptVersion: Int64
    public let generation: Int64
}

public enum RecordingFileResolutionResult: Sendable {
    case restored(version: Int64)
    case revised(version: Int64)
    case deleted(DeleteSession)
}
