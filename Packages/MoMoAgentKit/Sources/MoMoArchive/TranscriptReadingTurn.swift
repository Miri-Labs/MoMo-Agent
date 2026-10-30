import Foundation

/// Reading groups retain every durable span for correction, citation and playback.
public struct TranscriptReadingTurn: Identifiable, Sendable {
    public var id: UUID { source.spanID }
    public var source: SourceReference { paragraphs[0].source }
    public var sources: [SourceReference] { paragraphs.map(\.source) }
    public var recordedAt: Date { paragraphs[0].recordedAt }
    public var audioAvailable: Bool { paragraphs.allSatisfy(\.audioAvailable) }
    public var speaker: String? { paragraphs.first(where: { $0.attribution != nil })?.speaker ?? paragraphs[0].speaker }
    public var attribution: SpeakerAttribution? { paragraphs.first(where: { $0.attribution != nil })?.attribution }
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
        let readable = paragraphs.filter(\.hasReadableText)
        var groups: [[TimelineParagraph]] = []
        for idx in readable.indices {
            let next = readable[idx]
            let following = idx + 1 < readable.count ? readable[idx + 1] : nil
            if let prior = groups.last, let last = prior.last,
               canJoin(prior, last: last, next: next, following: following, breaks: breaks) {
                groups[groups.count - 1].append(next)
            } else {
                groups.append([next])
            }
        }
        return groups.map { Self(paragraphs: $0) }
    }

    private static func sameAttributedIdentity(_ a: SpeakerAttribution, _ b: SpeakerAttribution,
                                               speakerA: String?, speakerB: String?) -> Bool {
        guard a.isUser == b.isUser, speakerA == speakerB else { return false }
        return a.personID != nil ? a.personID == b.personID : b.personID == nil && a.clusterID == b.clusterID
    }

    private static func sameEpochContinuity(_ last: TimelineParagraph, _ next: TimelineParagraph,
                                            maxGap: Double, breaks: [Date]) -> Bool {
        guard next.startsNewSpeakerTurn != true, last.audioAvailable == next.audioAvailable,
              last.source.sessionID == next.source.sessionID, last.source.generation == next.source.generation,
              last.source.transcriptVersion == next.source.transcriptVersion,
              let a = last.audioSource, let b = next.audioSource, a.epochID == b.epochID,
              a.timebaseHz > 0, a.timebaseHz == b.timebaseHz, b.frames.start >= a.frames.end else { return false }
        let end = a.wallClockAnchor.addingTimeInterval(Double(a.frames.end) / a.timebaseHz)
        let gap = next.recordedAt.timeIntervalSince(end)
        return gap >= -0.05 && gap <= maxGap && !breaks.contains(where: { $0 >= end && $0 <= next.recordedAt })
    }

    private static func canJoin(_ prior: [TimelineParagraph], last: TimelineParagraph,
                                next: TimelineParagraph, following: TimelineParagraph?,
                                breaks: [Date]) -> Bool {
        let first = prior[0]
        let duration = next.recordedAt.timeIntervalSince(first.recordedAt)
        let closesSentence = last.text.trimmingCharacters(in: .whitespacesAndNewlines).last
            .map { "。！？!?；;.".contains($0) } ?? false
        guard duration < 90, !(duration >= 30 && closesSentence) else { return false }

        let anchorParagraph = prior.last(where: { $0.attribution != nil }) ?? last

        switch (anchorParagraph.attribution, next.attribution) {
        case (let a?, let b?):
            // Allow natural conversational/thinking pauses up to 5 s for the same speaker.
            guard sameEpochContinuity(last, next, maxGap: 5.0, breaks: breaks) else { return false }
            return sameAttributedIdentity(a, b, speakerA: anchorParagraph.speaker, speakerB: next.speaker)

        case (let a?, nil):
            // Bridge an isolated short unattributed phrase (<= 2.5 s) only when immediately
            // flanked on both sides by the exact same attributed speaker.
            guard next.speaker == nil,
                  let nextAudio = next.audioSource, nextAudio.timebaseHz > 0,
                  Double(nextAudio.frames.count) / nextAudio.timebaseHz <= 2.5,
                  let following, let fAttr = following.attribution,
                  sameEpochContinuity(last, next, maxGap: 2.0, breaks: breaks),
                  sameEpochContinuity(next, following, maxGap: 2.0, breaks: breaks) else { return false }
            return sameAttributedIdentity(a, fAttr, speakerA: anchorParagraph.speaker, speakerB: following.speaker)

        case (nil, nil):
            // Unattributed speech may only join across an immediate unpunctuated window seam,
            // never across sentence endings or multi-second pauses where speakers may have switched.
            guard !closesSentence, sameEpochContinuity(last, next, maxGap: 0.6, breaks: breaks) else { return false }
            return last.speaker == next.speaker

        case (nil, _?):
            return false
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
