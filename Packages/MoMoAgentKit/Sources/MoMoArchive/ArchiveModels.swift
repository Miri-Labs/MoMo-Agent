import Foundation
import MoMoContracts

public enum ArchiveError: Error, Sendable, Equatable, LocalizedError {
    case database(Int32)
    case incompatibleDatabase(Int)
    case invalidInbox
    case checksumMismatch
    case byteCountMismatch
    case conflictingChunk(UUID)
    case conflictingEpoch(UUID)
    case sessionDeleted(UUID)
    case staleAttempt
    case staleSource
    case missingRecording(UUID)
    case missingTranscript(UUID)
    case projectionPending
    case projectionConflict
    case invalidQuery
    case invalidTranscript
    case operationConflict(UUID)
    case missingPlan(UUID)
    case planDeleted(UUID)
    case stalePlan

    public var errorDescription: String? {
        switch self {
        case .database(let code): String(localized: "本机资料库操作失败（SQLite \(code)），请稍后重试。", bundle: AppLanguage.resourceBundle)
        case .incompatibleDatabase: String(localized: "资料由较新版本创建，请更新应用后再打开。", bundle: AppLanguage.resourceBundle)
        case .invalidInbox: String(localized: "收到的资料不完整，正在等待重新同步。", bundle: AppLanguage.resourceBundle)
        case .checksumMismatch, .byteCountMismatch: String(localized: "音频未通过完整性检查，手表原音仍需保留。", bundle: AppLanguage.resourceBundle)
        case .conflictingChunk, .conflictingEpoch: String(localized: "录音片段的记录不一致，请在转录中检查。", bundle: AppLanguage.resourceBundle)
        case .sessionDeleted: String(localized: "这次录音已删除。", bundle: AppLanguage.resourceBundle)
        case .staleAttempt, .staleSource: String(localized: "资料在读取期间已更新，请重试。", bundle: AppLanguage.resourceBundle)
        case .missingRecording: String(localized: "找不到对应的录音资料。", bundle: AppLanguage.resourceBundle)
        case .missingTranscript: String(localized: "这次录音还没有可读取的转录。", bundle: AppLanguage.resourceBundle)
        case .projectionPending: String(localized: "转录文件仍在更新，请稍后重试。", bundle: AppLanguage.resourceBundle)
        case .projectionConflict: String(localized: "转录文件与资料库存在差异，请在转录中检查。", bundle: AppLanguage.resourceBundle)
        case .invalidQuery: String(localized: "无法安全读取请求的资料。", bundle: AppLanguage.resourceBundle)
        case .invalidTranscript: String(localized: "转录资料未通过格式检查。", bundle: AppLanguage.resourceBundle)
        case .operationConflict: String(localized: "这次操作与已有操作记录不一致。", bundle: AppLanguage.resourceBundle)
        case .missingPlan, .planDeleted: String(localized: "找不到对应的事项记录。", bundle: AppLanguage.resourceBundle)
        case .stalePlan: String(localized: "事项记录已更新，请重新打开。", bundle: AppLanguage.resourceBundle)
        }
    }
}

public struct InboxItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public let directoryURL: URL
    public init(id: UUID, directoryURL: URL) { self.id = id; self.directoryURL = directoryURL }
}

public enum ReceiveResult: Sendable {
    case accepted(Receipt), duplicate(Receipt), restored(Receipt), deleted, expired, missing
    /// A previously listed item was consumed before this actor call ran. No new receipt is issued.
    case noLongerPending
}

public struct InboxProcessingResult: Sendable {
    public let itemID: UUID
    public let result: Result<ReceiveResult, Error>
}

public struct AnalysisTicket: Sendable {
    public let jobID: UUID
    public let attemptID: UUID
    public let sessionID: UUID
    public let chunkID: UUID
    public let expectedGeneration: Int64
    public let configurationHash: String
    public let manifest: ChunkManifest
    public let audioURL: URL
}

public struct TranscriptSpan: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let chunkID: UUID
    public let frames: FrameRange
    public let text: String
    public let speaker: String?
    public let attribution: SpeakerAttribution?
    public let sourceRanges: [TranscriptAudioRange]
    public let startsNewSpeakerTurn: Bool
    public init(id: UUID = UUID(), chunkID: UUID, frames: FrameRange, text: String, speaker: String? = nil, sourceRanges: [TranscriptAudioRange]? = nil, attribution: SpeakerAttribution? = nil, startsNewSpeakerTurn: Bool = false) {
        self.id = id; self.chunkID = chunkID; self.frames = frames; self.text = text; self.speaker = speaker
        self.sourceRanges = sourceRanges ?? [TranscriptAudioRange(chunkID: chunkID, frames: frames)]
        self.attribution = attribution
        self.startsNewSpeakerTurn = startsNewSpeakerTurn
    }
    private enum CodingKeys: String, CodingKey { case id, chunkID, frames, text, speaker, sourceRanges, attribution, startsNewSpeakerTurn }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let chunkID = try values.decode(UUID.self, forKey: .chunkID)
        let frames = try values.decode(FrameRange.self, forKey: .frames)
        self.init(id: try values.decode(UUID.self, forKey: .id), chunkID: chunkID, frames: frames,
                  text: try values.decode(String.self, forKey: .text), speaker: try values.decodeIfPresent(String.self, forKey: .speaker),
                  sourceRanges: try values.decodeIfPresent([TranscriptAudioRange].self, forKey: .sourceRanges),
                  attribution: try values.decodeIfPresent(SpeakerAttribution.self, forKey: .attribution),
                  startsNewSpeakerTurn: try values.decodeIfPresent(Bool.self, forKey: .startsNewSpeakerTurn) ?? false)
    }
}

public struct SourceReference: Codable, Sendable, Hashable {
    public let sessionID: UUID
    public let spanID: UUID
    public let transcriptVersion: Int64
    public let generation: Int64
    public init(sessionID: UUID, spanID: UUID, transcriptVersion: Int64, generation: Int64) {
        self.sessionID = sessionID; self.spanID = spanID
        self.transcriptVersion = transcriptVersion; self.generation = generation
    }

    public var citationURL: String {
        "momoagent://source/\(sessionID)/\(spanID)?version=\(transcriptVersion)&generation=\(generation)"
    }
}

public typealias TranscriptCitationSource = SourceReference

public struct TranscriptSpanLocation: Sendable {
    public let recordedAt: Date
    public let audioAvailable: Bool
    public var audioSource: TimelineAudioSource? = nil
}

public struct TranscriptDocument: Codable, Sendable {
    public let sessionID: UUID
    public let version: Int64
    public let generation: Int64
    public let spans: [TranscriptSpan]
    public let updatedAt: Date
    public func source(for span: TranscriptSpan) -> SourceReference {
        SourceReference(sessionID: sessionID, spanID: span.id, transcriptVersion: version, generation: generation)
    }
}

public struct RecordingSummary: Codable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let recordedAt: Date
    public let chunkCount: Int
    public let transcriptVersion: Int64
    public let generation: Int64
    public let sourceKind: SourceKind
    public let transcriptionState: RecordingTranscriptionState
    public let keepAudio: Bool
    public let audioState: RecordingAudioState
}

public enum RecordingTranscriptionState: String, Codable, Sendable {
    case pending, processing, noSpeech, transcribed, completedWithoutText, failed
}

public enum RecordingAudioState: String, Codable, Sendable {
    case available, partiallyExpired, expired, expiryPending, missingUnexpected, unavailable
}

public struct TranscriptSearchHit: Codable, Sendable {
    public let source: SourceReference
    public let text: String
    public let frames: FrameRange
}

public struct PlanDocument: Codable, Sendable, Identifiable {
    public let id: UUID
    public let operationID: UUID
    public let title: String
    public let body: String
    public let sources: [SourceReference]
    public let createdAt: Date
    public let revision: Int64
    public let updatedAt: Date

    init(id: UUID, operationID: UUID, title: String, body: String, sources: [SourceReference],
         createdAt: Date, revision: Int64 = 1, updatedAt: Date? = nil) {
        self.id = id; self.operationID = operationID; self.title = title; self.body = body
        self.sources = sources; self.createdAt = createdAt; self.revision = revision
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, operationID, title, body, sources, createdAt, revision, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  operationID: try values.decode(UUID.self, forKey: .operationID),
                  title: try values.decode(String.self, forKey: .title),
                  body: try values.decode(String.self, forKey: .body),
                  sources: try values.decode([SourceReference].self, forKey: .sources), createdAt: createdAt,
                  revision: try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 1,
                  updatedAt: try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt)
    }
}

public struct ArchiveContextStatus: Codable, Sendable {
    public let recordingCount: Int
    public let pendingAnalysisCount: Int
    public let latestTranscriptAt: Date?
}

public struct AudioLease: Sendable, Identifiable {
    public let id: UUID
    public let chunkID: UUID
    public let audioURL: URL
    public let manifest: ChunkManifest
}
