import Foundation

/// Reading groups retain every durable span for correction, citation and playback.
public struct TranscriptReadingTurn: Identifiable, Sendable {
    public var id: UUID { source.spanID }
    public var source: SourceReference { paragraphs[0].source }
    public var sources: [SourceReference] { paragraphs.map(\.source) }
    public var recordedAt: Date { paragraphs[0].recordedAt }
    public var audioAvailable: Bool { paragraphs.allSatisfy(\.audioAvailable) }
    public var speaker: String? { paragraphs[0].speaker }
    public var attribution: SpeakerAttribution? { paragraphs[0].attribution }
    public let paragraphs: [TimelineParagraph]
    public var text: String {
        paragraphs.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.reduce("") { text, next in
            // Latin word boundaries need a separator; CJK text does not.
            let needsSpace = text.last.map { $0.isASCII && !$0.isWhitespace } == true
                && next.first.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true
            return text + (needsSpace ? " " : "") + next
        }
    }

    public static func group(_ paragraphs: [TimelineParagraph], breaks: [Date] = []) -> [Self] {
        var groups: [[TimelineParagraph]] = []
        for next in paragraphs where next.hasReadableText {
            if let prior = groups.last, let last = prior.last,
               canJoin(prior[0], last, next, breaks: breaks) {
                groups[groups.count - 1].append(next)
            } else { groups.append([next]) }
        }
        return groups.map { Self(paragraphs: $0) }
    }

    private static func canJoin(_ first: TimelineParagraph, _ last: TimelineParagraph,
                                _ next: TimelineParagraph, breaks: [Date]) -> Bool {
        guard next.startsNewSpeakerTurn != true, last.audioAvailable == next.audioAvailable,
              last.source.sessionID == next.source.sessionID, last.source.generation == next.source.generation,
              last.source.transcriptVersion == next.source.transcriptVersion,
              let a = last.audioSource, let b = next.audioSource, a.epochID == b.epochID,
              a.timebaseHz > 0, a.timebaseHz == b.timebaseHz, b.frames.start >= a.frames.end else { return false }
        let end = a.wallClockAnchor.addingTimeInterval(Double(a.frames.end) / a.timebaseHz)
        let gap = next.recordedAt.timeIntervalSince(end)
        let duration = next.recordedAt.timeIntervalSince(first.recordedAt)
        let closesSentence = last.text.trimmingCharacters(in: .whitespacesAndNewlines).last
            .map { "。！？!?；;.".contains($0) } ?? false
        // Let a sentence finish across ASR windows. Start a new reading paragraph
        // at a completed sentence after 30s, with a 90s bound for unpunctuated speech.
        guard gap >= -0.05, gap <= 2, duration < 90, !(duration >= 30 && closesSentence),
              !breaks.contains(where: { $0 >= end && $0 <= next.recordedAt }) else { return false }
        switch (last.attribution, next.attribution) {
        case (nil, nil): return last.speaker == next.speaker
        case (let a?, let b?):
            guard a.confirmed == b.confirmed, a.isUser == b.isUser, last.speaker == next.speaker else { return false }
            return a.personID != nil && a.personID == b.personID || a.clusterID == b.clusterID
        default: return false
        }
    }
}

extension TranscriptDocument {
    public func readingTurns(locations: [UUID: TranscriptSpanLocation]) -> [TranscriptReadingTurn] {
        TranscriptReadingTurn.group(spans.map { span in
            TimelineParagraph(source: source(for: span), text: span.text,
                recordedAt: locations[span.id]?.recordedAt ?? updatedAt,
                audioAvailable: locations[span.id]?.audioAvailable == true, speaker: span.speaker,
                attribution: span.attribution, audioSource: locations[span.id]?.audioSource,
                startsNewSpeakerTurn: span.startsNewSpeakerTurn)
        })
    }
}
