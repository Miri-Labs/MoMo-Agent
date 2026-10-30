import Foundation

extension SpeechRecognition {
    /// Assign overlap tokens to disjoint cores while retaining the untouched native result.
    /// If ITN changed token spelling or the backend has no timestamps, preserve the full text.
    public func textOwned(by window: SpeechWindow,
                          after previous: (result: SpeechRecognition, window: SpeechWindow)? = nil) -> String {
        // Multi-clip turn decodes without full-window token timestamps already own disjoint core slices.
        if speakerTurns != nil, (tokens.isEmpty || tokens.count != timestamps.count) { return text }
        guard windowID == window.id, tokens.count == timestamps.count, !tokens.isEmpty,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return text }
        let lower = Float(window.modelCoreFrames.start - window.modelContextFrames.start) / 16_000
        let upper = Float(window.modelCoreFrames.end - window.modelContextFrames.start) / 16_000
        if speakerTurns != nil {
            let coreOwned = ownedTokens(lower: lower, upper: upper)
            var coreCursor = text.startIndex
            var coreStarts: [Int: String.Index] = [:]
            var matchedCore = true
            for index in coreOwned {
                while coreCursor < text.endIndex, text[coreCursor].isWhitespace {
                    coreCursor = text.index(after: coreCursor)
                }
                let spelling = tokens[index].replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
                guard !spelling.isEmpty,
                      let range = text.range(of: spelling, options: [.anchored, .caseInsensitive],
                        range: coreCursor..<text.endIndex) else {
                    matchedCore = false
                    break
                }
                coreStarts[index] = range.lowerBound
                coreCursor = range.upperBound
            }
            if matchedCore, text[coreCursor...].allSatisfy(\.isWhitespace) {
                guard let previous, let first = coreOwned.first,
                      previous.window.epochID == window.epochID,
                      previous.window.coreFrames.end == window.coreFrames.start,
                      previous.window.contextFrames.end > window.contextFrames.start,
                      let through = overlappingPrefix(after: previous.result, previousWindow: previous.window,
                                                      window: window, firstOwned: first) else {
                    return text
                }
                if through > first {
                    let kept = ownedTokens(lower: lower, upper: upper, startingAt: through)
                    guard let keptFirst = kept.first, let startIdx = coreStarts[keptFirst] else { return "" }
                    return String(text[startIdx..<text.endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if through < first {
                    let recovered = ownedTokens(lower: -.infinity, upper: lower, startingAt: through)
                        .filter { $0 < first }
                    if !recovered.isEmpty {
                        let prefix = recovered.map { tokens[$0].replacingOccurrences(of: "▁", with: " ") }.joined()
                        return (prefix + text).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return text
            }
        }
        var cursor = text.startIndex
        var starts: [String.Index] = []
        for token in tokens {
            let spelling = token.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard !spelling.isEmpty,
                  let range = text.range(of: spelling, options: [.anchored, .caseInsensitive],
                    range: cursor..<text.endIndex) else { return text }
            starts.append(range.lowerBound)
            cursor = range.upperBound
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
        }
        guard cursor == text.endIndex else { return text }
        var owned = ownedTokens(lower: lower, upper: upper)
        if let previous, let first = owned.first,
           previous.window.epochID == window.epochID, previous.window.coreFrames.end == window.coreFrames.start,
           previous.window.contextFrames.end > window.contextFrames.start,
           let through = overlappingPrefix(after: previous.result, previousWindow: previous.window,
                                            window: window, firstOwned: first) {
            // Both decodes can place the same token on opposite sides of the cut.
            // Continue after the last durable token, including any unowned prefix token.
            owned = ownedTokens(lower: -.infinity, upper: upper, startingAt: through)
        }
        guard let first = owned.first, let last = owned.last else { return "" }
        let end = last + 1 < starts.count ? starts[last + 1] : text.endIndex
        return String(text[starts[first]..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ownedTokens(lower: Float, upper: Float, startingAt: Int = 0) -> [Int] {
        var precedingWordOwned = false
        return timestamps.indices.filter { index in
            if tokens[index].contains(where: { $0.isLetter || $0.isNumber }) {
                precedingWordOwned = index >= startingAt && timestamps[index] >= lower && timestamps[index] < upper
            }
            // A punctuation timestamp can fall after the cut while the word it
            // closes belongs to this core. Keep the mark with that word.
            return precedingWordOwned
        }
    }

    private func overlappingPrefix(after previous: SpeechRecognition, previousWindow: SpeechWindow,
                                   window: SpeechWindow, firstOwned: Int) -> Int? {
        guard previous.windowID == previousWindow.id,
              previous.tokens.count == previous.timestamps.count,
              previous.timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(previous.timestamps, previous.timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        let oldLower = Float(previousWindow.modelCoreFrames.start - previousWindow.modelContextFrames.start) / 16_000
        let oldUpper = Float(previousWindow.modelCoreFrames.end - previousWindow.modelContextFrames.start) / 16_000
        let prevTarget = previous.text.filter { !$0.isWhitespace }
        let prevFullMatches = previous.tokens.joined().replacingOccurrences(of: "▁", with: " ")
            .filter({ !$0.isWhitespace }) == prevTarget
        let prevCoreMatches = previous.speakerTurns != nil
            && previous.ownedTokens(lower: oldLower, upper: oldUpper)
                .map({ previous.tokens[$0] }).joined().replacingOccurrences(of: "▁", with: " ")
                .filter({ !$0.isWhitespace }) == prevTarget
        guard prevFullMatches || prevCoreMatches else { return nil }
        guard let last = previous.timestamps.indices.last(where: {
            previous.timestamps[$0] >= oldLower && previous.timestamps[$0] < oldUpper
        }) else { return nil }
        let rate = Double(window.coreFrames.count) / Double(window.modelCoreFrames.count) * 16_000
        let oldRate = Double(previousWindow.coreFrames.count) / Double(previousWindow.modelCoreFrames.count) * 16_000
        var best: (through: Int, count: Int, distance: Double)?
        for count in 2...max(2, min(12, last + 1, tokens.count)) where count <= last + 1 && count <= tokens.count {
            for start in 0...min(firstOwned, tokens.count - count) {
                var distance: Double = 0
                var matches = true
                for offset in 0..<count {
                    let oldIndex = last - count + 1 + offset, newIndex = start + offset
                    let oldTime = Double(previousWindow.contextFrames.start) + Double(previous.timestamps[oldIndex]) * oldRate
                    let newTime = Double(window.contextFrames.start) + Double(timestamps[newIndex]) * rate
                    let delta = abs(oldTime - newTime) / rate
                    if previous.tokens[oldIndex] != tokens[newIndex] || delta > 0.24 { matches = false; break }
                    distance += delta
                }
                let mean = distance / Double(count)
                if matches, best == nil || mean < best!.distance || (mean == best!.distance && count > best!.count) {
                    best = (start + count, count, mean)
                }
            }
        }
        if let best { return best.through }
        // A short preceding core can own only one token. If both decodes agree on
        // that unique anchor, retain words after it even when their clocks cross
        // the cut in opposite directions. Ambiguous repetitions keep timestamp ownership.
        let anchor = previous.tokens[last]
        guard previous.tokens.filter({ $0 == anchor }).count == 1,
              tokens.filter({ $0 == anchor }).count == 1,
              let index = tokens.firstIndex(of: anchor), index <= firstOwned else { return nil }
        let oldTime = Double(previousWindow.contextFrames.start) + Double(previous.timestamps[last]) * oldRate
        let newTime = Double(window.contextFrames.start) + Double(timestamps[index]) * rate
        return abs(oldTime - newTime) / rate <= 0.24 ? index + 1 : nil
    }
}
