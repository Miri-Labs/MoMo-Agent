import AVFoundation
import Foundation
import Observation
import SwiftUI
import MoMoAgentClient

/// Native macOS audio player for Mac-stored original recording chunks (`context/audio/`).
/// Supports continuous multi-chunk timeline playback, seeking to any transcript span wall-clock
/// timestamp, and direct playback from `momoagent://source/...` citations.
@MainActor @Observable
final class DesktopRecordingAudioPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var sourceID: String?
    private(set) var chunks: [SourceAudioChunkItem] = []
    private(set) var isPlaying = false
    private(set) var currentTimeSec: Double = 0
    private(set) var totalDurationSec: Double = 0
    private(set) var activeChunkIndex: Int = 0
    private(set) var error: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var tickTimer: Task<Void, Never>?

    var hasAudio: Bool { chunks.contains(where: \.exists) }

    var timelineStartWallClock: Double? { chunks.first?.recordedAt }

    var currentWallClock: Double? {
        guard let start = timelineStartWallClock else { return nil }
        return start + currentTimeSec
    }

    func load(sourceID: String, chunks: [SourceAudioChunkItem]) {
        if self.sourceID == sourceID && self.chunks == chunks { return }
        stop()
        self.sourceID = sourceID
        self.chunks = chunks.filter(\.exists).sorted {
            if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
            if $0.chunkSeq != $1.chunkSeq { return $0.chunkSeq < $1.chunkSeq }
            return $0.chunkId < $1.chunkId
        }
        self.totalDurationSec = self.chunks.reduce(0.0) { $0 + $1.durationSec }
        self.currentTimeSec = 0
        self.activeChunkIndex = 0
        self.error = nil
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play(fromOffset: currentTimeSec)
        }
    }

    func play(atWallClock timestamp: Double) {
        guard !chunks.isEmpty else { return }
        var acc = 0.0
        for (idx, chunk) in chunks.enumerated() {
            if timestamp <= chunk.endAt || idx == chunks.count - 1 {
                let within = max(0.0, min(chunk.durationSec, timestamp - chunk.recordedAt))
                play(fromOffset: acc + within)
                return
            }
            acc += chunk.durationSec
        }
        play(fromOffset: 0)
    }

    func seek(toOffset offsetSec: Double) {
        let clamped = max(0.0, min(totalDurationSec, offsetSec))
        currentTimeSec = clamped
        guard isPlaying else { return }
        let (chosenIdx, withinChunk) = chunkPosition(forOffset: clamped)
        if chosenIdx == activeChunkIndex, let p = player {
            p.currentTime = min(max(0, withinChunk), max(0, p.duration - 0.05))
        } else {
            startChunk(index: chosenIdx, offsetInChunk: withinChunk)
        }
    }

    func play(fromOffset offsetSec: Double) {
        guard !chunks.isEmpty else { return }
        let clamped = max(0.0, min(max(0.0, totalDurationSec - 0.05), offsetSec))
        let (chosenIdx, withinChunk) = chunkPosition(forOffset: clamped)
        if chosenIdx == activeChunkIndex, let p = player {
            p.currentTime = min(max(0, withinChunk), max(0, p.duration - 0.05))
            p.play()
            isPlaying = true
            updateCurrentTime()
            startTimer()
            return
        }
        startChunk(index: chosenIdx, offsetInChunk: withinChunk)
    }

    private func chunkPosition(forOffset offsetSec: Double) -> (index: Int, withinChunk: Double) {
        var acc = 0.0
        for (idx, chunk) in chunks.enumerated() {
            if offsetSec < acc + chunk.durationSec || idx == chunks.count - 1 {
                return (idx, max(0.0, offsetSec - acc))
            }
            acc += chunk.durationSec
        }
        return (0, 0)
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
    }

    private func startChunk(index: Int, offsetInChunk: Double) {
        guard chunks.indices.contains(index), let path = chunks[index].path else {
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
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, self.isPlaying else { return }
                self.updateCurrentTime()
            }
        }
    }

    private func updateCurrentTime() {
        let prefix = chunks.prefix(activeChunkIndex).reduce(0.0) { $0 + $1.durationSec }
        let local = player?.currentTime ?? 0
        currentTimeSec = min(totalDurationSec, prefix + local)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finishedPlayer: AVAudioPlayer, successfully flag: Bool) {
        let finishedID = ObjectIdentifier(finishedPlayer)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == finishedID else { return }
            let nextIdx = self.activeChunkIndex + 1
            if flag && self.chunks.indices.contains(nextIdx) {
                self.startChunk(index: nextIdx, offsetInChunk: 0)
            } else {
                self.stop()
                self.currentTimeSec = 0
            }
        }
    }
}

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

/// Click-to-lock sheet on macOS transcripts separating `assign` vs `enroll_voiceprint` + negative rejection.
struct DesktopSpeakerLockSheet: View {
    let model: DesktopModel
    let sourceID: String
    let span: SourceTextSpan
    let onCommitted: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [VoiceprintProfile] = []
    @State private var selectedProfileID: String?
    @State private var customName = ""
    @State private var isOwner = false
    @State private var enrollVoiceprint = true
    @State private var rematchHistory = true
    @State private var applyToCluster = true
    @State private var busy = false
    @State private var error: String?
    @State private var resultBanner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("绑定说话人与声纹")
                        .font(.system(size: 15, weight: .semibold))
                    if let current = span.speaker {
                        Text("当前标记：\(current)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let text = span.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MoMoPalette.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }

            Form {
                Section("选择已有声纹人物") {
                    if profiles.isEmpty {
                        Text("声纹名册为空，可在下方输入新姓名并一键收录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("人物", selection: $selectedProfileID) {
                            Text("新建或手动输入姓名…").tag(String?.none)
                            ForEach(profiles) { p in
                                Text(p.isOwner ? "\(p.name)（我 · \(p.sampleCount) 条声纹）" : "\(p.name)（\(p.sampleCount) 条声纹）")
                                    .tag(Optional(p.id))
                            }
                        }
                    }
                }

                if selectedProfileID == nil {
                    Section("或输入新人物") {
                        TextField("姓名（例如：张三、Alex）", text: $customName)
                        Toggle("这是我本人（设为机主「我」）", isOn: $isOwner)
                    }
                }

                Section("声纹锁定策略") {
                    Toggle("应用到本次录音中该说话人的全部片段", isOn: $applyToCluster)
                    Toggle("同时记住 TA 的声音（加入声纹名册）", isOn: $enrollVoiceprint)
                    if enrollVoiceprint {
                        Toggle("立刻自动回填所有历史录音（<100ms）", isOn: $rematchHistory)
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(MoMoPalette.failure)
            }
            if let resultBanner {
                Text(resultBanner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let current = span.speaker, !current.isEmpty, !current.hasPrefix("说话人") {
                    Button("这不是「\(current)」", role: .destructive) {
                        Task { await rejectCurrent() }
                    }
                    .disabled(busy)
                }
                Spacer()
                Button("确认锁定") {
                    Task { await commitBinding() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || (selectedProfileID == nil && !isOwner && customName.trimmingCharacters(in: .whitespaces).isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 470)
        .task {
            if let fetched = try? await model.voiceprintProfiles() {
                profiles = fetched
            }
        }
    }

    private func commitBinding() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            let res = try await model.bindTranscriptSpeaker(
                sourceID: sourceID,
                spanIDs: [span.id],
                clusterKey: span.clusterKey,
                profileID: selectedProfileID,
                targetName: selectedProfileID == nil ? (isOwner && trimmed.isEmpty ? "我" : trimmed) : nil,
                isOwner: selectedProfileID == nil ? isOwner : false,
                enrollVoiceprint: enrollVoiceprint,
                rematchHistory: rematchHistory,
                scope: applyToCluster ? "cluster" : "selection"
            )
            if let rm = res.rematch, rm.updatedSpans > 0 {
                resultBanner = "已锁定 \(res.targetName) 并回填 \(rm.updatedSpans) 段历史记录（\(Int(rm.elapsedMs)) ms）"
            }
            onCommitted()
            dismiss()
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
            onCommitted()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
