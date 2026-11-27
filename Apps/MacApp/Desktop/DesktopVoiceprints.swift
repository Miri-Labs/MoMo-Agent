import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient

private final class MacSampleClipDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

/// Minimal AI-native Mac Settings pane for Voiceprints & Transcription (「声纹与转录」).
/// Voiceprint enrollment via microphone lives on iPhone; Mac manages profiles, playback,
/// file import, and transcript-driven speaker learning.
struct DesktopVoiceprintsAndSpeechView: View {
    @Bindable var model: DesktopModel
    @State private var profiles: [VoiceprintProfile] = []
    @State private var txStatus: MacTranscriptionStatus?
    @State private var settings = MacSpeechSettings()
    @State private var hotwordsText = ""
    @State private var showAdvanced = false
    @State private var busyMessage: String?
    @State private var statusBanner: String?
    @State private var error: String?

    @State private var showingNewProfileSheet = false
    @State private var editingProfile: VoiceprintProfile?
    @State private var playingProfileID: String?
    @State private var clipPlayer: AVAudioPlayer?
    @State private var clipDelegate = MacSampleClipDelegate()

    private var sortedProfiles: [VoiceprintProfile] {
        profiles.sorted { ($0.isOwner ? 0 : 1) < ($1.isOwner ? 0 : 1) }
    }

    var body: some View {
        Form {
            peopleSection
            transcriptionSection
            advancedSection
        }
        .formStyle(.grouped)
        .task { await reloadAll() }
        .onDisappear { stopPlayback() }
        .sheet(isPresented: $showingNewProfileSheet) {
            NewVoiceprintProfileSheet(model: model, hasOwner: profiles.contains(where: \.isOwner)) {
                Task { await reloadAll() }
            }
        }
        .sheet(item: $editingProfile) { profile in
            EditVoiceprintProfileSheet(model: model, profile: profile) {
                Task { await reloadAll() }
            }
        }
    }

    // MARK: - 1. People (Clean management + playback; mic recording lives on iPhone)

    private var peopleSection: some View {
        Section("人物") {
            if sortedProfiles.isEmpty {
                Label("在 iPhone 录下本人声音，或在转录中点击说话人", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedProfiles) { profile in
                    personRow(profile)
                }
            }

            HStack {
                Button {
                    showingNewProfileSheet = true
                } label: {
                    Label("添加人物", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                if let busyMessage {
                    ProgressView().controlSize(.mini)
                    Text(busyMessage).font(.caption).foregroundStyle(.secondary)
                } else if let statusBanner {
                    Text(statusBanner).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(MoMoPalette.failure)
            }
        }
    }

    private func personRow(_ profile: VoiceprintProfile) -> some View {
        let isPlaying = (playingProfileID == profile.id)
        let firstPlayable = profile.samples.first(where: \.hasClip)
        return HStack(spacing: 10) {
            Circle()
                .fill(profile.isOwner ? MoMoPalette.successBackground : MoMoPalette.ink.opacity(0.07))
                .frame(width: 30, height: 30)
                .overlay {
                    Text(String(profile.name.prefix(1)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(profile.isOwner ? MoMoPalette.success : MoMoPalette.ink)
                }

            HStack(spacing: 6) {
                Text(profile.name)
                    .font(.callout.weight(.medium))
                if profile.isOwner {
                    Text("本人")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(MoMoPalette.success)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(MoMoPalette.successBackground, in: Capsule())
                }
            }

            Spacer(minLength: 8)

            if profile.sampleCount > 0 {
                Text(String(format: "%.0fs", max(1, profile.totalCleanSeconds)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let sample = firstPlayable {
                Button {
                    Task { await togglePlay(profileID: profile.id, sampleID: sample.id) }
                } label: {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isPlaying ? MoMoPalette.success : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPlaying ? "停止试听" : "试听声纹")
            }

            Menu {
                Button("编辑…") { editingProfile = profile }
                Button("导入音频…") { importAudioSample(for: profile) }
                Divider()
                Button("删除", role: .destructive) {
                    Task { await deleteProfile(profile) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    // MARK: - 2. Transcription (Auto-saving, clean, zero jargon)

    private var transcriptionSection: some View {
        Section("转录") {
            Toggle(isOn: Binding(
                get: { !settings.paused },
                set: { active in
                    settings.paused = !active
                    Task { await saveSettings(silent: true) }
                }
            )) {
                HStack(spacing: 6) {
                    Text("自动转录")
                    if let pending = txStatus?.queue.pending, pending > 0 {
                        Text("处理中 · \(pending)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Picker("语言", selection: Binding(
                get: { settings.languageHint },
                set: { val in
                    settings.languageHint = val
                    Task { await saveSettings(silent: true) }
                }
            )) {
                Text("自动").tag("auto")
                Text("中文").tag("中文")
                Text("English").tag("English")
                Text("日本語").tag("日本語")
                Text("한국어").tag("한국어")
            }

            TextField("热词", text: $hotwordsText, prompt: Text("人名、专有名词，逗号分隔"))
                .onSubmit { Task { await saveSettings(silent: false) } }
        }
    }

    // MARK: - 3. Advanced (Collapsed by default)

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级", isExpanded: $showAdvanced) {
                HStack {
                    Text("语音灵敏度")
                    Spacer()
                    Slider(value: $settings.vadThreshold, in: 0.15...0.85, step: 0.05) { editing in
                        if !editing { Task { await saveSettings(silent: true) } }
                    }
                    .frame(width: 160)
                    Text(String(format: "%.2f", settings.vadThreshold))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                HStack {
                    Text("声纹严格度")
                    Spacer()
                    Slider(value: $settings.speakerLockThreshold, in: 0.40...0.80, step: 0.02) { editing in
                        if !editing { Task { await saveSettings(silent: true) } }
                    }
                    .frame(width: 160)
                    Text(String(format: "%.2f", settings.speakerLockThreshold))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }

                Stepper("原音保留 \(settings.audioRetentionDays) 天", value: Binding(
                    get: { settings.audioRetentionDays },
                    set: { val in
                        settings.audioRetentionDays = val
                        Task { await saveSettings(silent: true) }
                    }
                ), in: 1...365)

                if let st = txStatus?.storage {
                    LabeledContent("原音缓存") {
                        Text(String(format: "%.1f MB", st.totalMb))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button("重新匹配历史") { Task { await triggerRematch() } }
                        .disabled(profiles.isEmpty || busyMessage != nil)
                    Button("释放模型内存") {
                        model.speechHost.unloadHeavyModels()
                        statusBanner = "已释放内存"
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reloadAll() async {
        error = nil
        model.speechHost.refreshStatus()
        do {
            async let p = model.voiceprintProfiles()
            async let st = model.transcriptionStatus()
            let (fetchedProfiles, fetchedStatus) = try await (p, st)
            profiles = fetchedProfiles
            txStatus = fetchedStatus
            settings = fetchedStatus.settings
            hotwordsText = settings.customHotwords.joined(separator: ", ")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveSettings(silent: Bool) async {
        error = nil
        settings.customHotwords = hotwordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            settings = try await model.updateSpeechSettings(settings)
            hotwordsText = settings.customHotwords.joined(separator: ", ")
            if !silent { statusBanner = "已保存" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteProfile(_ profile: VoiceprintProfile) async {
        stopPlayback()
        do {
            try await model.deleteVoiceprintProfile(id: profile.id)
            await reloadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importAudioSample(for profile: VoiceprintProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busyMessage = "学习声纹中…"; error = nil
            defer { busyMessage = nil }
            do {
                let data = try Data(contentsOf: url)
                let res = try await model.enrollVoiceprintSample(
                    profileID: profile.id,
                    audioData: data,
                    filename: url.lastPathComponent,
                    sourceDevice: "mac_import"
                )
                statusBanner = res.rematch.updatedSpans > 0
                    ? "已学习「\(profile.name)」· 更新 \(res.rematch.updatedSpans) 处"
                    : "已学习「\(profile.name)」"
                await reloadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func togglePlay(profileID: String, sampleID: String) async {
        if playingProfileID == profileID {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            let data = try await model.fetchVoiceprintSampleAudio(profileID: profileID, sampleID: sampleID)
            let p = try AVAudioPlayer(data: data)
            let pid = profileID
            clipDelegate.onFinish = {
                Task { @MainActor in
                    if playingProfileID == pid {
                        playingProfileID = nil
                        clipPlayer = nil
                    }
                }
            }
            p.delegate = clipDelegate
            p.play()
            clipPlayer = p
            playingProfileID = profileID
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stopPlayback() {
        clipPlayer?.stop()
        clipPlayer = nil
        playingProfileID = nil
    }

    private func triggerRematch() async {
        busyMessage = "匹配中…"; error = nil
        defer { busyMessage = nil }
        do {
            let res = try await model.rematchVoiceprints()
            statusBanner = "更新 \(res.updatedSpans) 处"
            await model.loadContext(silent: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NewVoiceprintProfileSheet: View {
    let model: DesktopModel
    let hasOwner: Bool
    let onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isOwner = false
    @State private var aliasesText = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加人物").font(.headline)
            Form {
                TextField("姓名", text: $name)
                    .focused($nameFocused)
                if !hasOwner {
                    Toggle("这是我本人", isOn: $isOwner)
                }
                TextField("别名", text: $aliasesText, prompt: Text("可选，逗号分隔"))
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(MoMoPalette.failure) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || (!isOwner && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(18)
        .frame(width: 360, height: 240)
        .onAppear { nameFocused = true }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await model.createVoiceprintProfile(
                name: trimmed.isEmpty && isOwner ? "我" : trimmed,
                isOwner: isOwner,
                aliases: aliases
            )
            dismiss()
            onCreated()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EditVoiceprintProfileSheet: View {
    let model: DesktopModel
    @State var profile: VoiceprintProfile
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isOwner: Bool
    @State private var aliasesText: String
    @State private var notes: String
    @State private var error: String?
    @State private var busy = false
    @State private var clipPlayer: AVAudioPlayer?

    init(model: DesktopModel, profile: VoiceprintProfile, onSaved: @escaping () -> Void) {
        self.model = model
        _profile = State(initialValue: profile)
        self.onSaved = onSaved
        _name = State(initialValue: profile.name)
        _isOwner = State(initialValue: profile.isOwner)
        _aliasesText = State(initialValue: profile.aliases.joined(separator: ", "))
        _notes = State(initialValue: profile.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(profile.name).font(.headline)
            Form {
                Section {
                    TextField("姓名", text: $name)
                    TextField("别名", text: $aliasesText, prompt: Text("逗号分隔"))
                    TextField("备注", text: $notes, prompt: Text("可选"))
                    Toggle("本人", isOn: $isOwner)
                }
                if !profile.samples.isEmpty {
                    Section("声音") {
                        ForEach(profile.samples) { sample in
                            HStack(spacing: 10) {
                                if sample.hasClip {
                                    Button {
                                        Task { await playSample(sample) }
                                    } label: {
                                        Image(systemName: "play.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(String(format: "%.1fs", sample.cleanSeconds))
                                    .monospacedDigit()
                                Text(friendlySource(sample))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    Task { await deleteSample(sample) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(MoMoPalette.failure) }
            HStack {
                Button("删除", role: .destructive) {
                    Task {
                        busy = true; defer { busy = false }
                        do {
                            try await model.deleteVoiceprintProfile(id: profile.id)
                            onSaved()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(busy)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 390, height: 380)
        .onDisappear { clipPlayer?.stop() }
    }

    private func friendlySource(_ s: VoiceprintSample) -> String {
        if s.sourceKind == "transcript_bind" || s.sourceKind == "transcript_confirm" { return "录音" }
        if s.sourceDevice.contains("iphone") { return "iPhone" }
        if s.sourceDevice.contains("mac") { return "Mac" }
        return "导入"
    }

    private func playSample(_ sample: VoiceprintSample) async {
        do {
            let data = try await model.fetchVoiceprintSampleAudio(profileID: profile.id, sampleID: sample.id)
            let p = try AVAudioPlayer(data: data)
            p.play()
            clipPlayer = p
        } catch { self.error = error.localizedDescription }
    }

    private func deleteSample(_ sample: VoiceprintSample) async {
        do {
            try await model.deleteVoiceprintSample(profileID: profile.id, sampleID: sample.id)
            if let fresh = try await model.voiceprintProfiles().first(where: { $0.id == profile.id }) {
                profile = fresh
            }
            onSaved()
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            _ = try await model.updateVoiceprintProfile(
                id: profile.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                isOwner: isOwner,
                aliases: aliases,
                memoryFile: profile.memoryFile,
                notes: notes
            )
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
