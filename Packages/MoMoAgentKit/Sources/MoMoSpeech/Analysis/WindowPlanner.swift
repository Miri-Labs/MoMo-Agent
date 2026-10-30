import Foundation
import MoMoContracts

struct WindowPlanner {
    let configuration: SpeechConfiguration
    let fingerprint: String

    func windows(ranges: [Range<Int64>], input: SpeechInputSet, availableThrough: Int64,
                 tailClosed: Bool) throws -> [SpeechWindow] {
        var windows: [SpeechWindow] = []
        for (index, detected) in ranges.enumerated() {
            let end = min(detected.upperBound, availableThrough)
            guard end > detected.lowerBound else { continue }
            let leftBoundary = index > 0 ? (ranges[index - 1].upperBound + detected.lowerBound) / 2 : 0
            let rightBoundary = index + 1 < ranges.count ? (end + ranges[index + 1].lowerBound) / 2 : availableThrough
            let left = max(0, max(detected.lowerBound - configuration.paddingFrames, leftBoundary))
            let right = min(availableThrough, min(end + configuration.paddingFrames, rightBoundary))
            var cursor = detected.lowerBound
            while cursor < end {
                let count = min(configuration.maximumCoreFrames, end - cursor)
                let last = cursor + count == end
                if last, count < configuration.maximumCoreFrames, index == ranges.count - 1, !tailClosed { break }
                let core = try FrameRange(start: cursor, count: count)
                let contextStart = cursor == detected.lowerBound ? left : cursor
                // A full 20s core always ends exactly at its boundary, even if the utterance later ends there.
                let contextEnd = last && count < configuration.maximumCoreFrames ? right : core.end
                let context = try FrameRange(start: contextStart, count: contextEnd - contextStart)
                windows.append(try makeWindow(core: core, context: context, input: input))
                cursor = core.end
            }
        }
        return windows
    }

    func makeWindow(core: FrameRange, context: FrameRange, input: SpeechInputSet) throws -> SpeechWindow {
        let sourceCore = try input.sourceRange(core), sourceContext = try input.sourceRange(context)
        let sources = try input.inputs.compactMap { item -> SpeechWindowSource? in
            let m = item.envelope.manifest
            let start = max(m.frames.start, sourceContext.start), end = min(m.frames.end, sourceContext.end)
            guard end > start else { return nil }
            return SpeechWindowSource(chunkID: m.chunkID, manifestSHA256: item.envelope.manifestSHA256,
                                      audioSHA256: m.audioSHA256, sourceFrames: try FrameRange(start: start, count: end - start))
        }
        let replayHashes = input.inputs.filter {
            $0.envelope.manifest.frames.end > input.start && $0.envelope.manifest.frames.start < sourceContext.end
        }.map(\.envelope.manifestSHA256)
        struct Identity: Encodable {
            let sessionID: UUID; let epochID: UUID; let anchor: Int64
            let core: FrameRange; let context: FrameRange; let sources: [SpeechWindowSource]
            let replayHashes: [String]; let fingerprint: String
        }
        let identity = Identity(sessionID: input.sessionID, epochID: input.epochID, anchor: input.start,
                                core: core, context: context, sources: sources, replayHashes: replayHashes, fingerprint: fingerprint)
        return SpeechWindow(id: ContentHash.sha256(try WireJSON.encode(identity)), sessionID: input.sessionID,
                            epochID: input.epochID, analysisAnchor: input.start, coreFrames: sourceCore,
                            contextFrames: sourceContext, modelCoreFrames: core, modelContextFrames: context,
                            sources: sources, replayInputManifestHashes: replayHashes, configurationFingerprint: fingerprint)
    }

    static func subtract(_ removed: [FrameRange], from range: FrameRange) throws -> [FrameRange] {
        var cursor = range.start
        var result: [FrameRange] = []
        for item in try FrameRange.union(removed) {
            let start = max(range.start, item.start), end = min(range.end, item.end)
            guard end > start else { continue }
            if start > cursor { result.append(try FrameRange(start: cursor, count: start - cursor)) }
            cursor = max(cursor, end)
        }
        if cursor < range.end { result.append(try FrameRange(start: cursor, count: range.end - cursor)) }
        return result
    }
}
