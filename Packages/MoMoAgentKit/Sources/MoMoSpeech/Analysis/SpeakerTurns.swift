import Foundation
import MoMoContracts

/// Acoustic turns are independent of punctuation, token spelling and VAD windows.
struct SpeakerTurn: Sendable {
    var frames: Range<Int>
    var audioFrames: Range<Int>
    var evidence: SpeakerEvidence

    init(frames: Range<Int>, audioFrames: Range<Int>? = nil, evidence: SpeakerEvidence) {
        self.frames = frames
        self.audioFrames = audioFrames ?? frames
        self.evidence = evidence
    }

    static func sameVoice(_ a: SpeakerEvidence, _ b: SpeakerEvidence) -> Bool {
        guard a.localSpeaker > 0, b.localSpeaker > 0 else { return false }
        if a.localSpeaker == b.localSpeaker { return true }
        // Track numbers are comparable inside the same stitched segmentation block only.
        if (a.localSpeaker - 1) / 3 == (b.localSpeaker - 1) / 3 { return false }
        return a.modelRevision == b.modelRevision && a.hasVoiceprint && b.hasVoiceprint
            && SpeakerEvidence.similarity(a.embedding, b.embedding) >= 0.8
    }

    static func plan(_ evidence: [SpeakerEvidence], core: Range<Int>,
                     sampleBounds: Range<Int>? = nil) -> [Self] {
        guard !core.isEmpty else { return [] }
        let bounds = sampleBounds ?? core
        let collarSamples = 2_560 // 160 ms acoustic collar for consonant onsets/codas
        let audible = evidence.filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
                && $0.start * 16_000 < Double(core.upperBound) && $0.end * 16_000 > Double(core.lowerBound)
        }.sorted { $0.start < $1.start }
        var groups: [(first: SpeakerEvidence, last: SpeakerEvidence, best: SpeakerEvidence)] = []
        for value in audible {
            if let last = groups.last, sameVoice(last.last, value), value.start - last.last.end <= 2 {
                groups[groups.count - 1].last = value
                if value.cleanSeconds > last.best.cleanSeconds { groups[groups.count - 1].best = value }
            } else { groups.append((value, value, value)) }
        }
        var cursor = core.lowerBound
        return groups.indices.compactMap { index in
            let group = groups[index]
            let end: Int
            if index + 1 == groups.count { end = core.upperBound }
            else {
                let boundary = (group.last.end + groups[index + 1].first.start) / 2
                end = min(core.upperBound, max(cursor, Int((boundary * 16_000).rounded())))
            }
            guard end > cursor else { return nil }
            let start = cursor
            defer { cursor = end }
            let leftFloor = index == 0
                ? bounds.lowerBound
                : max(bounds.lowerBound, Int((groups[index - 1].last.end * 16_000).rounded(.up)))
            let rightCeil = index + 1 == groups.count
                ? bounds.upperBound
                : min(bounds.upperBound, Int((groups[index + 1].first.start * 16_000).rounded(.down)))
            let audioStart = min(start, max(leftFloor, start - collarSamples))
            let audioEnd = max(end, min(rightCeil, end + collarSamples))
            let sample = group.best
            let clean = max(0, min(sample.end, Double(end) / 16_000) - max(sample.start, Double(start) / 16_000))
            return Self(frames: start..<end, audioFrames: audioStart..<audioEnd,
                evidence: SpeakerEvidence(start: sample.start, end: sample.end,
                    localSpeaker: sample.localSpeaker, embedding: sample.embedding,
                    cleanSeconds: min(sample.cleanSeconds, clean), modelRevision: sample.modelRevision))
        }
    }
}

public struct SpeakerTurnTranscript: Codable, Equatable, Sendable {
    public let text: String
    public let start: Double
    public let end: Double
    public let evidence: SpeakerEvidence
}

extension SpeechRecognition {
    fileprivate static func isWordToken(_ token: String) -> Bool {
        token.contains { $0.isLetter || $0.isNumber }
    }

    fileprivate static func isSentenceEndingToken(_ token: String) -> Bool {
        token.contains { "。！？!?；;".contains($0) }
    }

    /// Use genuine word times first: short interjections need the full decode's language context.
    func alignedSpeakerTurns(_ turns: [SpeakerTurn]) -> [SpeakerTurnTranscript]? {
        guard !turns.isEmpty, !tokens.isEmpty, tokens.count == timestamps.count,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        var cursor = text.startIndex
        var starts: [String.Index] = []
        for token in tokens {
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            let spelling = token.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard !spelling.isEmpty, let range = text.range(of: spelling, options: [.anchored, .caseInsensitive],
                range: cursor..<text.endIndex) else { return nil }
            starts.append(range.lowerBound)
            cursor = range.upperBound
        }
        guard text[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        var ownership: [Int?] = []
        for index in timestamps.indices {
            if !Self.isWordToken(tokens[index]) {
                ownership.append(ownership.last.flatMap { $0 })
                continue
            }
            let onset = Double(timestamps[index])
            guard onset * 16_000 >= Double(turns[0].frames.lowerBound),
                  onset * 16_000 < Double(turns[turns.count - 1].frames.upperBound) else {
                ownership.append(nil); continue
            }
            // sherpa exposes CTC onsets, not word ends. Bound the next-onset interval
            // to 200 ms so a following silence cannot move a word to another turn.
            let width = index + 1 < timestamps.count ? min(0.2, Double(timestamps[index + 1]) - onset) : 0
            let frame = min((onset + width / 2) * 16_000, Double(turns[turns.count - 1].frames.upperBound).nextDown)
            let match = turns.indices.first { frame >= Double(turns[$0].frames.lowerBound) && frame < Double(turns[$0].frames.upperBound) }
            // Punctuation belongs to the preceding words, never its own speaker row.
            ownership.append(match)
        }

        // Snap speaker transitions to adjacent sentence-ending punctuation within 300 ms
        // so acoustic midpoint jitter does not strand a trailing syllable + "。" across turns.
        if turns.count > 1 {
            for tA in 0..<(turns.count - 1) {
                let tB = tA + 1
                let boundarySec = Double(turns[tA].frames.upperBound) / 16_000
                guard let lastA = ownership.indices.last(where: { ownership[$0] == tA }),
                      let firstB = ownership.indices.first(where: { ownership[$0] == tB }),
                      firstB == lastA + 1 else { continue }
                let wordsInA = ownership.indices.filter { ownership[$0] == tA && Self.isWordToken(tokens[$0]) }
                let wordsInB = ownership.indices.filter { ownership[$0] == tB && Self.isWordToken(tokens[$0]) }
                if lastA >= 1, ownership[lastA - 1] == tA,
                   Self.isSentenceEndingToken(tokens[lastA - 1]), Self.isWordToken(tokens[lastA]),
                   wordsInA.count >= 2, abs(Double(timestamps[lastA]) - boundarySec) <= 0.30 {
                    ownership[lastA] = tB
                } else if firstB + 1 < tokens.count, ownership[firstB + 1] == tB,
                          Self.isWordToken(tokens[firstB]), Self.isSentenceEndingToken(tokens[firstB + 1]),
                          wordsInB.count >= 2, abs(Double(timestamps[firstB]) - boundarySec) <= 0.30 {
                    ownership[firstB] = tA
                    ownership[firstB + 1] = tA
                }
            }
        }

        let assigned = ownership.compactMap { $0 }
        guard zip(assigned, assigned.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        return turns.indices.compactMap { turnIndex in
            let turn = turns[turnIndex]
            let indexes = ownership.indices.filter { ownership[$0] == turnIndex }
            guard let first = indexes.first, let last = indexes.last else { return nil }
            let end = last + 1 < starts.count ? starts[last + 1] : text.endIndex
            return SpeakerTurnTranscript(text: String(text[starts[first]..<end]),
                start: Double(turn.frames.lowerBound) / 16_000, end: Double(turn.frames.upperBound) / 16_000,
                evidence: turn.evidence)
        }
    }
}
