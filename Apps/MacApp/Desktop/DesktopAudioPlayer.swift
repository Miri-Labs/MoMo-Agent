import AVFoundation
import Foundation
import Observation
import SwiftUI
import MoMoAgentClient

/// Span timestamp interval used for per-sentence playback and live highlight tracking.
struct DesktopAudioSpanInterval: Equatable, Sendable {
    let id: String
    let startWallClock: Double
    let endWallClock: Double?
}

/// Pure wall-clock <-> concatenated player offset mapper across Mac-stored recording chunks.
struct DesktopAudioTimeline: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let chunk: SourceAudioChunkItem
        let playerStartOffset: Double
        let playerEndOffset: Double
    }

    private static let coverageToleranceSec: Double = 0.5
    private static let tailPadSec: Double = 0.15

    let segments: [Segment]
    let totalDurationSec: Double

    init(chunks: [SourceAudioChunkItem], windowStart: Double? = nil, windowEnd: Double? = nil) {
        let valid = chunks.filter { $0.exists && $0.durationSec > 0 }.sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            if $0.chunkSeq != $1.chunkSeq { return $0.chunkSeq < $1.chunkSeq }
            return $0.chunkId < $1.chunkId
        }
        let scoped: [SourceAudioChunkItem]
        if let wStart = windowStart, let wEnd = windowEnd {
            let lo = min(wStart, wEnd) - 1.0
            let hi = max(wStart, wEnd) + 1.0
            scoped = valid.filter { $0.endAt >= lo && $0.recordedAt <= hi }
        } else {
            scoped = valid
        }
        var built: [Segment] = []
        built.reserveCapacity(scoped.count)
        var acc = 0.0
        for chunk in scoped {
            let next = acc + chunk.durationSec
            built.append(Segment(chunk: chunk, playerStartOffset: acc, playerEndOffset: next))
            acc = next
        }
        self.segments = built
        self.totalDurationSec = acc
    }

    var isEmpty: Bool { segments.isEmpty }

    func canPlay(startWallClock: Double, endWallClock: Double? = nil) -> Bool {
        spanOffsetRange(startWallClock: startWallClock, endWallClock: endWallClock) != nil
    }

    func spanOffsetRange(startWallClock: Double, endWallClock: Double? = nil) -> (startOffset: Double, endOffset: Double?)? {
        guard !segments.isEmpty, startWallClock.isFinite else { return nil }
        let effectiveEnd = max(startWallClock, endWallClock ?? startWallClock)
        let startIdx = segments.firstIndex {
            startWallClock >= $0.chunk.recordedAt - Self.coverageToleranceSec
                && startWallClock < $0.chunk.endAt - 0.02
        } ?? segments.firstIndex {
            $0.chunk.endAt + Self.coverageToleranceSec >= startWallClock
                && $0.chunk.recordedAt - Self.coverageToleranceSec <= effectiveEnd
        }
        guard let startIdx else { return nil }

        let startSeg = segments[startIdx]
        let withinStart = max(0.0, min(max(0.0, startSeg.chunk.durationSec - 0.05), startWallClock - startSeg.chunk.recordedAt))
        let startOffset = startSeg.playerStartOffset + withinStart

        guard let endWall = endWallClock, endWall.isFinite, endWall > startWallClock else {
            return (startOffset, nil)
        }

        let paddedEndWall = endWall + Self.tailPadSec
        var lastContiguousIdx = startIdx
        for idx in startIdx..<segments.count {
            if idx > startIdx {
                let gap = segments[idx].chunk.recordedAt - segments[idx - 1].chunk.endAt
                if gap > 1.5 { break }
            }
            lastContiguousIdx = idx
            let seg = segments[idx]
            if paddedEndWall <= seg.chunk.endAt {
                let withinEnd = max(0.0, min(seg.chunk.durationSec, paddedEndWall - seg.chunk.recordedAt))
                let rawEnd = min(seg.playerEndOffset, seg.playerStartOffset + withinEnd)
                return (startOffset, max(min(totalDurationSec, startOffset + 0.25), rawEnd))
            }
        }
        return (startOffset, segments[lastContiguousIdx].playerEndOffset)
    }

    func chunkPosition(forOffset offsetSec: Double) -> (index: Int, withinChunk: Double) {
        guard !segments.isEmpty else { return (0, 0) }
        let clamped = max(0.0, min(totalDurationSec, offsetSec))
        for (idx, seg) in segments.enumerated() {
            if clamped < seg.playerEndOffset || idx == segments.count - 1 {
                let within = max(0.0, min(seg.chunk.durationSec, clamped - seg.playerStartOffset))
                return (idx, within)
            }
        }
        return (0, 0)
    }

    func wallClock(forOffset offsetSec: Double) -> Double? {
        guard !segments.isEmpty else { return nil }
        let (idx, within) = chunkPosition(forOffset: offsetSec)
        return segments[idx].chunk.recordedAt + within
    }

    func activeSpanID(atWallClock wall: Double, spans: [DesktopAudioSpanInterval]) -> String? {
        guard !spans.isEmpty else { return nil }
        // Binary search the last span whose startWallClock <= wall + 0.12
        var lo = 0
        var hi = spans.count - 1
        var candidate: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].startWallClock <= wall + 0.12 {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let idx = candidate else { return nil }
        let sp = spans[idx]
        let upperBound: Double
        if let end = sp.endWallClock, end > sp.startWallClock {
            upperBound = end + 0.25
        } else if idx + 1 < spans.count {
            upperBound = min(sp.startWallClock + 15.0, spans[idx + 1].startWallClock)
        } else {
            upperBound = sp.startWallClock + 15.0
        }
        return wall <= upperBound ? sp.id : nil
    }
}

/// Native macOS audio player for Mac-stored original recording chunks (`context/audio/`).
/// Supports continuous multi-chunk timeline playback, per-sentence clip playback (`toggleSpan`),
/// seeking to any transcript span wall-clock timestamp, and direct playback from `momoagent://source/...` citations.
@MainActor @Observable
final class DesktopRecordingAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var sourceID: String?
    private(set) var timeline = DesktopAudioTimeline(chunks: [])
    private(set) var chunksRevision: UInt64 = 0
    private(set) var isPlaying = false
    private(set) var currentTimeSec: Double = 0
    private(set) var activeChunkIndex: Int = 0
    private(set) var activeSpanID: String?
    private(set) var error: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickTimer: Task<Void, Never>?
    @ObservationIgnored private var spanIntervals: [DesktopAudioSpanInterval] = []
    @ObservationIgnored private var activeSpanRange: (id: String, startOffset: Double, endOffset: Double?)?
    @ObservationIgnored private var stopAtOffsetSec: Double?

    var chunks: [SourceAudioChunkItem] { timeline.segments.map(\.chunk) }

    var totalDurationSec: Double { timeline.totalDurationSec }

    var hasAudio: Bool { !timeline.isEmpty }

    var timelineStartWallClock: Double? { timeline.segments.first?.chunk.recordedAt }

    var currentWallClock: Double? {
        timeline.wallClock(forOffset: currentTimeSec)
    }

    func load(
        sourceID: String,
        chunks: [SourceAudioChunkItem],
        windowStart: Double? = nil,
        windowEnd: Double? = nil,
        spans: [DesktopAudioSpanInterval] = []
    ) {
        let nextTimeline = DesktopAudioTimeline(chunks: chunks, windowStart: windowStart, windowEnd: windowEnd)
        self.spanIntervals = spans.sorted { $0.startWallClock < $1.startWallClock }
        if self.sourceID == sourceID && self.timeline == nextTimeline { return }
        stop()
        self.sourceID = sourceID
        self.timeline = nextTimeline
        self.currentTimeSec = 0
        self.activeChunkIndex = 0
        self.activeSpanID = nil
        self.activeSpanRange = nil
        self.stopAtOffsetSec = nil
        self.error = nil
        self.chunksRevision &+= 1
    }

    func updateSpanIntervals(_ spans: [DesktopAudioSpanInterval]) {
        self.spanIntervals = spans.sorted { $0.startWallClock < $1.startWallClock }
    }

    func canPlaySpan(startWallClock: Double?, endWallClock: Double? = nil) -> Bool {
        guard let startWallClock else { return false }
        return timeline.canPlay(startWallClock: startWallClock, endWallClock: endWallClock)
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            let resumeOffset = currentTimeSec >= max(0.0, totalDurationSec - 0.1) ? 0.0 : currentTimeSec
            play(fromOffset: resumeOffset, clearSpanScope: true)
        }
    }

    func toggleSpan(id: String, startWallClock: Double, endWallClock: Double? = nil) {
        if let active = activeSpanRange, active.id == id {
            if isPlaying {
                pause()
            } else {
                stopAtOffsetSec = active.endOffset
                let canResumeMidSpan: Bool = if let endOff = active.endOffset {
                    currentTimeSec >= active.startOffset && currentTimeSec < endOff - 0.12
                } else {
                    currentTimeSec >= active.startOffset && currentTimeSec < totalDurationSec - 0.12
                }
                play(fromOffset: canResumeMidSpan ? currentTimeSec : active.startOffset, clearSpanScope: false)
            }
            return
        }
        guard let range = timeline.spanOffsetRange(startWallClock: startWallClock, endWallClock: endWallClock) else {
            error = String(localized: "这段原音未同步或已清理")
            return
        }
        activeSpanID = id
        activeSpanRange = (id: id, startOffset: range.startOffset, endOffset: range.endOffset)
        stopAtOffsetSec = range.endOffset
        play(fromOffset: range.startOffset, clearSpanScope: false)
    }

    func play(atWallClock timestamp: Double, endWallClock: Double? = nil) {
        guard let range = timeline.spanOffsetRange(startWallClock: timestamp, endWallClock: endWallClock) else {
            error = String(localized: "这段原音未同步或已清理")
            return
        }
        activeSpanRange = nil
        stopAtOffsetSec = range.endOffset
        play(fromOffset: range.startOffset, clearSpanScope: false)
    }

    func seek(toOffset offsetSec: Double) {
        let clamped = max(0.0, min(totalDurationSec, offsetSec))
        stopAtOffsetSec = nil
        activeSpanRange = nil
        currentTimeSec = clamped
        syncActiveSpanForContinuousPlayback()
        guard isPlaying else { return }
        let (chosenIdx, withinChunk) = timeline.chunkPosition(forOffset: clamped)
        if chosenIdx == activeChunkIndex, let p = player {
            p.currentTime = min(max(0, withinChunk), max(0, p.duration - 0.05))
        } else {
            startChunk(index: chosenIdx, offsetInChunk: withinChunk)
        }
    }

    func play(fromOffset offsetSec: Double, clearSpanScope: Bool = true) {
        guard !timeline.isEmpty else { return }
        if clearSpanScope {
            stopAtOffsetSec = nil
            activeSpanRange = nil
        }
        let clamped = max(0.0, min(max(0.0, totalDurationSec - 0.05), offsetSec))
        let (chosenIdx, withinChunk) = timeline.chunkPosition(forOffset: clamped)
        if chosenIdx == activeChunkIndex, let p = player {
            p.currentTime = min(max(0, withinChunk), max(0, p.duration - 0.05))
            p.play()
            isPlaying = true
            error = nil
            updateCurrentTime()
            startTimer()
            return
        }
        startChunk(index: chosenIdx, offsetInChunk: withinChunk)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        tickTimer?.cancel()
        tickTimer = nil
    }

    func stop() {
        tickTimer?.cancel()
        tickTimer = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        isPlaying = false
        activeSpanID = nil
        activeSpanRange = nil
        stopAtOffsetSec = nil
    }

    private func startChunk(index: Int, offsetInChunk: Double) {
        guard timeline.segments.indices.contains(index),
              let path = timeline.segments[index].chunk.path else {
            stop()
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            player?.delegate = nil
            player?.stop()
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.currentTime = min(max(0, offsetInChunk), max(0, p.duration - 0.05))
            p.play()
            self.player = p
            self.activeChunkIndex = index
            self.isPlaying = true
            self.error = nil
            updateCurrentTime()
            startTimer()
        } catch {
            self.error = error.localizedDescription
            self.isPlaying = false
        }
    }

    private func startTimer() {
        tickTimer?.cancel()
        tickTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                guard let self, self.isPlaying else { return }
                self.updateCurrentTime()
            }
        }
    }

    private func syncActiveSpanForContinuousPlayback() {
        guard activeSpanRange == nil else { return }
        let nextSpan = currentWallClock.flatMap { timeline.activeSpanID(atWallClock: $0, spans: spanIntervals) }
        if activeSpanID != nextSpan {
            activeSpanID = nextSpan
        }
    }

    private func finishScopedSpanPlayback(at offsetSec: Double) {
        pause()
        currentTimeSec = min(totalDurationSec, offsetSec)
        stopAtOffsetSec = nil
        activeSpanRange = nil
        if activeSpanID != nil {
            activeSpanID = nil
        }
    }

    private func updateCurrentTime() {
        guard timeline.segments.indices.contains(activeChunkIndex) else { return }
        let prefix = timeline.segments[activeChunkIndex].playerStartOffset
        let local = player?.currentTime ?? 0
        let nextTime = min(totalDurationSec, prefix + local)
        if let stopAt = stopAtOffsetSec, nextTime >= stopAt {
            finishScopedSpanPlayback(at: stopAt)
            return
        }
        currentTimeSec = nextTime
        syncActiveSpanForContinuousPlayback()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(finishedPlayer)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finishedID else { return }
            let nextIdx = self.activeChunkIndex + 1
            if let stopAt = self.stopAtOffsetSec,
               !self.timeline.segments.indices.contains(nextIdx) || self.timeline.segments[nextIdx].playerStartOffset >= stopAt - 0.05 {
                self.finishScopedSpanPlayback(at: stopAt)
                return
            }
            if flag && self.timeline.segments.indices.contains(nextIdx) {
                self.startChunk(index: nextIdx, offsetInChunk: 0)
            } else {
                self.stop()
                self.currentTimeSec = 0
            }
        }
    }
}

#if !MOMO_STANDALONE_AUDIO_TESTS
/// Compact native macOS audio playback bar pinned inside `DesktopTranscripts` and citation previews.
struct DesktopAudioPlaybackBar: View {
    @Bindable var player: DesktopRecordingAudioPlayer

    var body: some View {
        if player.hasAudio {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(MoMoPalette.ink.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "暂停播放原音" : "播放录音原音")

                Text(Self.formatDuration(player.currentTimeSec))
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(MoMoPalette.muted)
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { player.currentTimeSec },
                        set: { player.seek(toOffset: $0) }
                    ),
                    in: 0...max(0.1, player.totalDurationSec)
                )
                .controlSize(.small)

                Text(Self.formatDuration(player.totalDurationSec))
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(MoMoPalette.muted)
                    .frame(width: 44, alignment: .trailing)

                if let err = player.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MoMoPalette.failure)
                        .help(err)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(MoMoPalette.borderSubtle, lineWidth: 0.75)
            }
        }
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// Compact AI-native speaker quick-picker (1-click existing person or type name + Return).
struct DesktopSpeakerLockSheet: View {
    let model: DesktopModel
    let sourceID: String
    let span: SourceTextSpan
    let onCommitted: (String?) -> Void
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [VoiceprintProfile] = []
    @State private var query = ""
    @State private var enrollVoiceprint = true
    @State private var applyToCluster = true
    @State private var busy = false
    @State private var error: String?
    @FocusState private var inputFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredProfiles: [VoiceprintProfile] {
        let sorted = profiles.sorted { ($0.isOwner ? 0 : 1) < ($1.isOwner ? 0 : 1) }
        guard !trimmedQuery.isEmpty else { return sorted }
        return sorted.filter {
            $0.name.localizedStandardContains(trimmedQuery)
                || $0.aliases.contains(where: { $0.localizedStandardContains(trimmedQuery) })
        }
    }

    private var canCreateTypedName: Bool {
        !trimmedQuery.isEmpty
            && !profiles.contains(where: { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame })
    }

    private var currentNamedSpeaker: String? {
        guard let s = span.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, !s.hasPrefix("说话人") else { return nil }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inline search / create field (auto-focused: type + Enter = instant bind)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("选择或输入姓名…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit {
                        if let first = filteredProfiles.first, trimmedQuery.caseInsensitiveCompare(first.name) == .orderedSame {
                            Task { await pickExisting(first) }
                        } else if canCreateTypedName {
                            Task { await createAndBind(trimmedQuery) }
                        } else if let first = filteredProfiles.first {
                            Task { await pickExisting(first) }
                        }
                    }
                if busy {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Direct 1-click people list
            ScrollView {
                VStack(spacing: 2) {
                    if !profiles.contains(where: \.isOwner) && (trimmedQuery.isEmpty || "我".localizedStandardContains(trimmedQuery)) {
                        personRow(name: "我", badge: "本人", isOwner: true, selected: span.isOwner == true) {
                            Task { await createAndBind("我", isOwner: true) }
                        }
                    }
                    ForEach(filteredProfiles) { person in
                        let isSelected = (span.voiceProfileId == person.id)
                            || (person.isOwner && span.isOwner == true)
                            || (span.speaker == person.name)
                        personRow(
                            name: person.name,
                            badge: person.isOwner ? "本人" : nil,
                            isOwner: person.isOwner,
                            selected: isSelected
                        ) {
                            Task { await pickExisting(person) }
                        }
                    }
                    if canCreateTypedName {
                        Button {
                            Task { await createAndBind(trimmedQuery) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.accentColor)
                                Text("新建「\(trimmedQuery)」")
                                    .font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text("↵")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 200)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(MoMoPalette.failure)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()

            // Compact bottom bar: scope + learn toggle + reject
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $applyToCluster) {
                        Text("本场").tag(true)
                        Text("仅此句").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 112)

                    Spacer(minLength: 6)

                    Toggle("记住声纹", isOn: $enrollVoiceprint)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if let current = currentNamedSpeaker {
                    HStack {
                        Button("不是「\(current)」", role: .destructive) {
                            Task { await rejectCurrent() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MoMoPalette.failure)
                        .disabled(busy)
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 268)
        .onAppear { inputFocused = true }
        .task {
            if let fetched = try? await model.voiceprintProfiles() {
                profiles = fetched
            }
        }
    }

    private func personRow(name: String, badge: String?, isOwner: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOwner ? MoMoPalette.successBackground : MoMoPalette.ink.opacity(0.08))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Text(String(name.prefix(1)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isOwner ? MoMoPalette.success : MoMoPalette.ink)
                    }
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(MoMoPalette.ink)
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MoMoPalette.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(MoMoPalette.successBackground, in: Capsule())
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isOwner ? MoMoPalette.success : MoMoPalette.ink)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? MoMoPalette.ink.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func pickExisting(_ person: VoiceprintProfile) async {
        await commit(profileID: person.id, targetName: nil, isOwner: person.isOwner)
    }

    private func createAndBind(_ name: String, isOwner: Bool = false) async {
        await commit(profileID: nil, targetName: name, isOwner: isOwner)
    }

    private func commit(profileID: String?, targetName: String?, isOwner: Bool) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let res = try await model.bindTranscriptSpeaker(
                sourceID: sourceID,
                spanIDs: [span.id],
                clusterKey: span.clusterKey,
                profileID: profileID,
                targetName: targetName,
                isOwner: isOwner,
                enrollVoiceprint: enrollVoiceprint,
                rematchHistory: enrollVoiceprint,
                scope: applyToCluster ? "cluster" : "selection"
            )
            let updated = res.rematch?.updatedSpans ?? 0
            let banner = updated > 0 ? "已设为「\(res.targetName)」· 同步更新 \(updated) 处" : "已设为「\(res.targetName)」"
            onCommitted(banner)
            if let onClose { onClose() } else { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rejectCurrent() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await model.rejectSpeakerMatch(
                sourceID: sourceID,
                profileID: span.voiceProfileId,
                speakerName: span.speaker,
                spanIDs: [span.id],
                clusterKey: span.clusterKey
            )
            onCommitted("已取消「\(span.speaker ?? "")」标记")
            if let onClose { onClose() } else { dismiss() }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
