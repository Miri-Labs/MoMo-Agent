import Foundation

/// Timings are seconds from the ASR context's first sample; vectors never leave the local archive.
public struct SpeakerEvidence: Codable, Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let localSpeaker: Int
    public let embedding: [Float]
    public let cleanSeconds: Double
    public let modelRevision: String
    public init(start: Double, end: Double, localSpeaker: Int, embedding: [Float], cleanSeconds: Double, modelRevision: String) {
        self.start = start; self.end = end; self.localSpeaker = localSpeaker
        self.embedding = embedding; self.cleanSeconds = cleanSeconds; self.modelRevision = modelRevision
    }
    public var hasVoiceprint: Bool {
        (embedding.count == 192 || embedding.count == 256) && embedding.allSatisfy(\.isFinite)
            && abs(embedding.reduce(0) { $0 + $1 * $1 } - 1) < 0.02
    }
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard (a.count == 192 || a.count == 256), b.count == a.count else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

public struct EnrolledSpeakerPrototype: Codable, Equatable, Sendable {
    public let personID: UUID
    public let embedding: [Float]
    public let modelRevision: String
    public init(personID: UUID, embedding: [Float], modelRevision: String) {
        self.personID = personID
        self.embedding = embedding
        self.modelRevision = modelRevision
    }
}

public struct SpeakerTranscriptPart: Sendable {
    public let text: String
    public let frames: FrameRange
    public let evidence: SpeakerEvidence?
    public init(text: String, frames: FrameRange, evidence: SpeakerEvidence?) {
        self.text = text; self.frames = frames; self.evidence = evidence
    }
}
