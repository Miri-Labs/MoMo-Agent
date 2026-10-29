import Foundation

extension SpeechRecognition {
    /// Assign overlap tokens to disjoint cores while retaining the untouched native result.
    /// If ITN changed token spelling or the backend has no timestamps, preserve the full text.
    public func textOwned(by window: SpeechWindow,
                          after previous: (result: SpeechRecognition, window: SpeechWindow)? = nil) -> String {
        // Turn decodes already own disjoint slices of this window's core.
        if speakerTurns != nil { return text }
        guard windowID == window.id, tokens.count == timestamps.count, !tokens.isEmpty,
              timestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return text }
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
        let lower = Float(window.modelCoreFrames.start - window.modelContextFrames.start) / 16_000
        let upper = Float(window.modelCoreFrames.end - window.modelContextFrames.start) / 16_000
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
              zip(previous.timestamps, previous.timestamps.dropFirst()).allSatisfy({ $0 <= $1 }),
              previous.tokens.joined().replacingOccurrences(of: "▁", with: " ").filter({ !$0.isWhitespace })
                == previous.text.filter({ !$0.isWhitespace }) else { return nil }
        let oldLower = Float(previousWindow.modelCoreFrames.start - previousWindow.modelContextFrames.start) / 16_000
        let oldUpper = Float(previousWindow.modelCoreFrames.end - previousWindow.modelContextFrames.start) / 16_000
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
