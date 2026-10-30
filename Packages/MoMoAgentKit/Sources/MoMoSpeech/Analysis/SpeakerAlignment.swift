import Foundation
import MoMoContracts

extension SpeechRecognition {
    /// Preserve the existing overlap/ITN text exactly. Ambiguous text stays unattributed.
    public func speakerParts(text ownedText: String, window: SpeechWindow) throws -> [SpeakerTranscriptPart]? {
        if let speakerTurns, !speakerTurns.isEmpty {
            guard !ownedText.isEmpty else { return nil }
            let turnText = speakerTurns.map(\.text).joined()
            var adjustedTurns: [SpeakerTurnTranscript]?
            if ownedText == text || ownedText == turnText {
                adjustedTurns = speakerTurns
                if ownedText != turnText, ownedText == text {
                    adjustedTurns = nil
                }
            } else if let match = turnText.range(of: ownedText, options: [.backwards]),
                      turnText[match.upperBound...].allSatisfy(\.isWhitespace) {
                var remainingPrefix = turnText.distance(from: turnText.startIndex, to: match.lowerBound)
                var remainingLen = ownedText.count
                var sliced: [SpeakerTurnTranscript] = []
                for turn in speakerTurns where remainingLen > 0 {
                    if remainingPrefix >= turn.text.count {
                        remainingPrefix -= turn.text.count
                        continue
                    }
                    let startIdx = turn.text.index(turn.text.startIndex, offsetBy: remainingPrefix)
                    remainingPrefix = 0
                    let avail = turn.text.distance(from: startIdx, to: turn.text.endIndex)
                    let take = min(avail, remainingLen)
                    let endIdx = turn.text.index(startIdx, offsetBy: take)
                    remainingLen -= take
                    let piece = String(turn.text[startIdx..<endIdx])
                    if !piece.isEmpty {
                        sliced.append(SpeakerTurnTranscript(
                            text: piece, start: turn.start, end: turn.end, evidence: turn.evidence))
                    }
                }
                if !sliced.isEmpty, sliced.map(\.text).joined() == ownedText {
                    adjustedTurns = sliced
                }
            } else {
                let trimmedTurnText = turnText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedTurnText.isEmpty,
                   let match = ownedText.range(of: trimmedTurnText, options: [.backwards, .anchored]) {
                    let prepended = String(ownedText[..<match.lowerBound])
                    var updated = speakerTurns
                    updated[0] = SpeakerTurnTranscript(
                        text: prepended + updated[0].text,
                        start: updated[0].start, end: updated[0].end, evidence: updated[0].evidence)
                    let joined = updated.map(\.text).joined()
                    if joined != ownedText, joined.trimmingCharacters(in: .whitespacesAndNewlines) == ownedText {
                        let lastIdx = updated.count - 1
                        updated[lastIdx] = SpeakerTurnTranscript(
                            text: updated[lastIdx].text.replacingOccurrences(
                                of: "\\s+$", with: "", options: .regularExpression),
                            start: updated[lastIdx].start, end: updated[lastIdx].end,
                            evidence: updated[lastIdx].evidence)
                    }
                    if updated.map(\.text).joined() == ownedText {
                        adjustedTurns = updated
                    }
                }
            }
            if let activeTurns = adjustedTurns, !activeTurns.isEmpty {
                let scale = Double(window.coreFrames.count) / Double(window.modelCoreFrames.count)
                let offset = Double(window.modelCoreFrames.start - window.modelContextFrames.start)
                var cursor = window.coreFrames.start
                var parts: [SpeakerTranscriptPart] = []
                parts.reserveCapacity(activeTurns.count)
                for (index, turn) in activeTurns.enumerated() {
                    let rawEnd = window.coreFrames.start + Int64(((turn.end * 16_000 - offset) * scale).rounded())
                    let remainingTurns = Int64(activeTurns.count - 1 - index)
                    let maxEnd = max(cursor, window.coreFrames.end - remainingTurns)
                    let end = index == activeTurns.count - 1
                        ? window.coreFrames.end
                        : min(maxEnd, max(cursor + 1, rawEnd))
                    if end <= cursor {
                        if let prev = parts.popLast() {
                            let mergedEv: SpeakerEvidence?
                            if let pe = prev.evidence {
                                mergedEv = SpeakerTurn.sameVoice(pe, turn.evidence)
                                    ? SpeakerTurn.mergeEvidence(pe, turn.evidence)
                                    : pe
                            } else {
                                mergedEv = turn.evidence
                            }
                            parts.append(SpeakerTranscriptPart(
                                text: prev.text + turn.text, frames: prev.frames, evidence: mergedEv))
                            continue
                        }
                        throw SpeechError.nativeResult
                    }
                    parts.append(SpeakerTranscriptPart(
                        text: turn.text,
                        frames: try FrameRange(start: cursor, count: end - cursor),
                        evidence: turn.evidence))
                    cursor = end
                }
                return parts
            }
        }
        guard let speakers, !speakers.isEmpty, !ownedText.isEmpty else { return nil }
        func singleSpeaker() -> [SpeakerTranscriptPart]? {
            let lower = Double(window.modelCoreFrames.start - window.modelContextFrames.start) / 16_000
            let upper = Double(window.modelCoreFrames.end - window.modelContextFrames.start) / 16_000
            let audible = speakers.filter { $0.start < upper && $0.end > lower }
            guard let anchor = audible.filter(\.hasVoiceprint).max(by: {
                ($0.cleanSeconds, $0.end - $0.start) < ($1.cleanSeconds, $1.end - $1.start)
            }), audible.allSatisfy({ item in
                item.hasVoiceprint
                    ? SpeakerTurn.sameVoice(anchor, item)
                    : (item.localSpeaker == anchor.localSpeaker || item.end - item.start <= 0.45)
            }) else { return nil }
            let clean = max(0, min(anchor.end, upper) - max(anchor.start, lower))
            return [.init(text: ownedText, frames: window.coreFrames, evidence: .init(start: anchor.start, end: anchor.end,
                localSpeaker: anchor.localSpeaker, embedding: anchor.embedding,
                cleanSeconds: anchor.cleanSeconds > 0 ? min(clean, anchor.cleanSeconds) : 0,
                modelRevision: anchor.modelRevision))]
        }
        guard let owned = text.range(of: ownedText), tokens.count == timestamps.count, !tokens.isEmpty,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return singleSpeaker() }
        guard text.range(of: ownedText, range: text.index(after: owned.lowerBound)..<text.endIndex) == nil else { return singleSpeaker() }
        var cursor = text.startIndex
        var ranges: [Range<String.Index>] = []
        for token in tokens {
            let spelling = token.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            guard !spelling.isEmpty, let range = text.range(of: spelling, options: [.anchored, .caseInsensitive], range: cursor..<text.endIndex) else { return singleSpeaker() }
            ranges.append(range); cursor = range.upperBound
        }
        guard text[cursor...].allSatisfy(\.isWhitespace) else { return singleSpeaker() }
        let indexes = ranges.indices.filter { ranges[$0].lowerBound >= owned.lowerBound && ranges[$0].upperBound <= owned.upperBound }
        guard let first = indexes.first, let last = indexes.last,
              ranges[first].lowerBound == owned.lowerBound else { return nil }

        func isWord(_ index: Int) -> Bool {
            tokens[index].contains { $0.isLetter || $0.isNumber }
        }
        func isSentenceEnd(_ index: Int) -> Bool {
            tokens[index].contains { "。！？!?；;".contains($0) }
        }
        // WhisperX-style attribution: exact containment first, then nearest voiceprinted turn within 280 ms
        // so CTC peak lead/lag does not create orphan unattributed 1-character spans.
        func wordEvidence(_ index: Int) -> Int? {
            let t = Double(timestamps[index])
            if let exact = speakers.indices.first(where: {
                speakers[$0].start <= t && speakers[$0].end > t && speakers[$0].hasVoiceprint
            }) {
                return exact
            }
            var bestIndex: Int?
            var bestDistance = 0.28
            for candidate in speakers.indices where speakers[candidate].hasVoiceprint {
                let s = speakers[candidate]
                let d = t < s.start ? (s.start - t) : (t > s.end ? (t - s.end) : 0)
                if d <= bestDistance {
                    bestDistance = d
                    bestIndex = candidate
                }
            }
            return bestIndex
        }

        let sliceCount = last - first + 1
        var matched = [Int?](repeating: nil, count: sliceCount)
        for offset in 0..<sliceCount {
            let tokenIdx = first + offset
            if isWord(tokenIdx) { matched[offset] = wordEvidence(tokenIdx) }
        }
        // Punctuation attaches to the preceding word's speaker (or the first following word if leading).
        for offset in 0..<sliceCount where !isWord(first + offset) {
            if offset > 0, let prev = matched[offset - 1] {
                matched[offset] = prev
            } else if let nextWord = ((offset + 1)..<sliceCount).first(where: { matched[$0] != nil }) {
                matched[offset] = matched[nextWord]
            }
        }
        // Bridge isolated 1-token unattributed dips flanked by the same voice within 1 s.
        if sliceCount >= 3 {
            for offset in 1..<(sliceCount - 1) where matched[offset] == nil {
                if let left = matched[offset - 1], let right = matched[offset + 1],
                   SpeakerTurn.sameVoice(speakers[left], speakers[right]),
                   Double(timestamps[first + offset + 1] - timestamps[first + offset - 1]) <= 1.0 {
                    matched[offset] = left
                }
            }
        }

        var groups: [(first: Int, last: Int, evidence: Int?)] = []
        for offset in 0..<sliceCount {
            let index = first + offset
            let match = matched[offset]
            let same = groups.last.map { prior in
                if let a = prior.evidence, let b = match { return SpeakerTurn.sameVoice(speakers[a], speakers[b]) }
                return prior.evidence == match
            } ?? false
            if same, !groups.isEmpty { groups[groups.count - 1].last = index }
            else { groups.append((index, index, match)) }
        }

        // Snap speaker transitions to adjacent sentence-ending punctuation within 300 ms.
        if groups.count > 1 {
            for g in 0..<(groups.count - 1) {
                guard groups[g].evidence != nil, groups[g + 1].evidence != nil else { continue }
                let leftLast = groups[g].last
                let rightFirst = groups[g + 1].first
                let leftWords = (groups[g].first...leftLast).filter(isWord)
                let rightWords = (rightFirst...groups[g + 1].last).filter(isWord)
                let boundarySec = speakers[groups[g + 1].evidence!].start
                if leftLast > groups[g].first, isSentenceEnd(leftLast - 1), isWord(leftLast),
                   leftWords.count >= 2, abs(Double(timestamps[leftLast]) - boundarySec) <= 0.30 {
                    groups[g].last = leftLast - 1
                    groups[g + 1].first = leftLast
                } else if rightFirst + 2 <= groups[g + 1].last, isWord(rightFirst),
                          !isWord(rightFirst + 1), isSentenceEnd(rightFirst + 1),
                          rightWords.count >= 2, abs(Double(timestamps[rightFirst]) - boundarySec) <= 0.30 {
                    groups[g].last = rightFirst + 1
                    groups[g + 1].first = rightFirst + 2
                }
            }
        }

        let ratio = Double(window.coreFrames.count) / Double(window.modelCoreFrames.count)
        let offset = Double(window.modelCoreFrames.start - window.modelContextFrames.start)
        func sourceFrame(_ seconds: Double) -> Int64 {
            window.coreFrames.start + Int64(((seconds * 16_000 - offset) * ratio).rounded())
        }
        var output: [SpeakerTranscriptPart] = []
        var frame = window.coreFrames.start
        for (i, group) in groups.enumerated() {
            let endIndex = group.last == last ? owned.upperBound : ranges[group.last + 1].lowerBound
            let endFrame = i == groups.count - 1 ? window.coreFrames.end : min(window.coreFrames.end,
                max(frame + 1, sourceFrame(Double(timestamps[group.last + 1]))))
            guard endFrame > frame else { return nil }
            let value = group.evidence.map { speakers[$0] }
            // Every learnable span must cover the evidence interval, not just one token of it.
            let duration = Double(endFrame - frame) / ratio / 16_000
            let clipped = value.map { SpeakerEvidence(start: $0.start, end: $0.end, localSpeaker: $0.localSpeaker,
                embedding: $0.embedding, cleanSeconds: min($0.cleanSeconds, duration), modelRevision: $0.modelRevision) }
            output.append(SpeakerTranscriptPart(text: String(text[ranges[group.first].lowerBound..<endIndex]),
                frames: try FrameRange(start: frame, count: endFrame - frame), evidence: clipped))
            frame = endFrame
        }
        guard output.map(\.text).joined() == ownedText else { return nil }
        return output
    }
}
