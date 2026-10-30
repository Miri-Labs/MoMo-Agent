import Foundation
import MoMoArchive

enum AudioPlaybackTarget: Equatable, Sendable {
    case recording(UUID, Int64)
    case transcript(SourceReference)
    case turn(SourceReference, [SourceReference])
    case window(TimelineWindowID, [TimelineAudioSource])

    var sessionID: UUID {
        switch self {
        case .recording(let id, _): id
        case .transcript(let source): source.sessionID
        case .turn(let source, _): source.sessionID
        case .window(_, let sources): sources[0].sessionID
        }
    }
    var generation: Int64 {
        switch self {
        case .recording(_, let value): value
        case .transcript(let source): source.generation
        case .turn(let source, _): source.generation
        case .window(_, let sources): sources[0].generation
        }
    }
    var source: SourceReference? {
        switch self {
        case .transcript(let source), .turn(let source, _): source
        default: nil
        }
    }
    static func readingTurn(_ turn: TranscriptReadingTurn) -> Self {
        turn.sources.count == 1 ? .transcript(turn.source) : .turn(turn.source, Array(turn.sources.dropFirst()))
    }
    var windowID: TimelineWindowID? { if case .window(let id, _) = self { id } else { nil } }
    var windowEnd: Date? {
        if case .window(_, let sources) = self {
            return sources.map { $0.wallClockAnchor.addingTimeInterval(Double($0.frames.end) / $0.timebaseHz) }.max()
        }
        return nil
    }
}

enum AudioPlaybackState: Equatable, Sendable { case loading, playing, paused, ended, failed }

struct AudioPlaybackSnapshot: Sendable {
    let target: AudioPlaybackTarget
    var state: AudioPlaybackState
    var position: Double
    let duration: Double?
    var canSeek: Bool
    var waveform: [Float]
    var waveformProgress: Double? = nil
    var waveformLoadedThrough: Double? = nil
    let recordedAt: Date?
    var gaps: [ClosedRange<Double>]
    var seekableRanges: [Range<Double>] = []

    /// An adjustable control must move across a missing interval, rather than retry it forever.
    func adjustedSeekPosition(forward: Bool) -> Double? {
        guard canSeek, let duration, duration.isFinite, duration > 0 else { return nil }
        let step = min(10, max(1, duration / 20))
        let proposed = min(duration, max(0, position + (forward ? step : -step)))
        if forward {
            for range in seekableRanges {
                if range.contains(proposed) { return proposed }
                if range.lowerBound >= proposed { return range.lowerBound }
            }
            if seekableRanges.last?.upperBound == duration { return duration }
        } else {
            for range in seekableRanges.reversed() {
                if range.contains(proposed) { return proposed }
                if range.upperBound <= proposed { return range.upperBound.nextDown }
            }
        }
        return nil
    }
}

/// A capture epoch has its own monotonic frame clock. Pauses between epochs are not audio;
/// holes *inside* an epoch retain their original width. No wall-clock adjustment changes seek.
struct PlaybackTimeline: Sendable {
    struct Segment: Sendable {
        let part: ArchivedPlaybackPart
        let start: Double
        let end: Double
        var archiveIndex = 0
    }
    let archives: [ArchivedPlaybackTimeline]
    var archive: ArchivedPlaybackTimeline { archives[0] }
    let segments: [Segment]
    let duration: Double?
    let recordedAt: Date?
    let gaps: [ClosedRange<Double>]

    init(_ archive: ArchivedPlaybackTimeline) {
        self.archives = [archive]
        var result: [Segment] = []
        var cursor = 0.0
        var currentEpoch: UUID?
        var epochBase = 0.0
        var originFrame: Int64 = 0
        for part in archive.parts {
            let manifest = part.manifest
            if currentEpoch != manifest.epochID {
                currentEpoch = manifest.epochID
                epochBase = cursor
                originFrame = archive.source == nil ? 0 : part.frames.start
            }
            let start = epochBase + Double(part.frames.start - originFrame) / manifest.timebaseHz
            let end = epochBase + Double(part.frames.end - originFrame) / manifest.timebaseHz
            result.append(Segment(part: part, start: start, end: end))
            cursor = max(cursor, end)
        }
        segments = result
        duration = cursor > 0 && cursor.isFinite ? cursor : nil
        if let first = archive.parts.first {
            recordedAt = first.manifest.wallClockAnchor.addingTimeInterval(Double(first.frames.start) / first.manifest.timebaseHz)
        } else { recordedAt = nil }
        var missing: [ClosedRange<Double>] = []
        cursor = 0
        for segment in result {
            if segment.start > cursor { missing.append(cursor...segment.start) }
            if !segment.part.audioAvailable { missing.append(segment.start...segment.end) }
            cursor = segment.end
        }
        gaps = missing
    }

    init(windows: [ArchivedPlaybackTimeline]) {
        archives = windows
        var result: [Segment] = []
        var missing: [ClosedRange<Double>] = []
        var cursor = 0.0
        for (index, archive) in windows.enumerated() {
            guard let source = archive.windowSource else { continue }
            let base = cursor
            var through = base
            for part in archive.parts {
                let start = base + Double(part.frames.start - source.frames.start) / source.timebaseHz
                let end = base + Double(part.frames.end - source.frames.start) / source.timebaseHz
                if start > through { missing.append(through...start) }
                if !part.audioAvailable { missing.append(start...end) }
                result.append(Segment(part: part, start: start, end: end, archiveIndex: index))
                through = end
            }
            cursor = base + Double(source.frames.count) / source.timebaseHz
            if cursor > through { missing.append(through...cursor) }
        }
        segments = result
        gaps = missing
        duration = cursor > 0 && cursor.isFinite ? cursor : nil
        recordedAt = windows.first?.windowSource?.recordedAt
    }

    func index(at position: Double) -> Int? {
        segments.firstIndex { $0.part.audioAvailable && position >= $0.start && position < $0.end }
    }

    func snapshot(target: AudioPlaybackTarget, state: AudioPlaybackState = .paused) -> AudioPlaybackSnapshot {
        AudioPlaybackSnapshot(target: target, state: state, position: 0, duration: duration,
                              canSeek: duration != nil && segments.contains { $0.part.audioAvailable },
                              waveform: [], waveformProgress: segments.contains(where: { $0.part.audioAvailable }) ? 0 : nil,
                              waveformLoadedThrough: 0, recordedAt: recordedAt, gaps: gaps,
                              seekableRanges: segments.filter { $0.part.audioAvailable }.map { $0.start..<$0.end })
    }
}
