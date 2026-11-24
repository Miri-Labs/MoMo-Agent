import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient

/// Native macOS microphone recorder for 2–60s voiceprint enrollment clips (16 kHz mono WAV).
@MainActor @Observable
final class MacVoiceprintRecorder {
    private(set) var isRecording = false
    private(set) var elapsedSeconds: Double = 0
    private(set) var level: Float = 0
    private(set) var error: String?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var outputURL: URL?
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    func start() {
        error = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-voiceprint-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                error = "无法启动麦克风录音，请检查麦克风权限。"
                return
            }
            self.recorder = rec
            self.outputURL = url
            self.elapsedSeconds = 0
            self.isRecording = true
            self.timerTask?.cancel()
            self.timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let r = self.recorder, r.isRecording else { return }
                    r.updateMeters()
                    let power = r.averagePower(forChannel: 0)
                    self.level = max(0, min(1, (power + 50) / 50))
                    self.elapsedSeconds = r.currentTime
                    if r.currentTime >= 60.0 {
                        r.stop()
                        self.isRecording = false
                        break
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stopAndReadData() -> Data? {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let url = outputURL else { return nil }
        outputURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    func cancel() {
        _ = stopAndReadData()
    }
}

/// Mac Settings pane for CoreML Speech Backend + Voiceprint Roster Management (「声纹与转录」).
struct DesktopVoiceprintsAndSpeechView: View {
    @Bindable var model: DesktopModel
    @State private var profiles: [VoiceprintProfile] = []
    @State private var txStatus: MacTranscriptionStatus?
    @State private var settings = MacSpeechSettings()
    @State private var hotwordsText = ""
    @State private var loading = false
    @State private var busyMessage: String?
    @State private var statusBanner: String?
    @State private var error: String?

    @State private var showingNewProfileSheet = false
    @State private var recordingProfile: VoiceprintProfile?
    @State private var editingProfile: VoiceprintProfile?
    @State private var clipPlayer: AVAudioPlayer?

    var body: some View {
        Form {
            engineStatusSection
            voiceprintRosterSection
            speechSettingsSection
        }
        .formStyle(.grouped)
        .task { await reloadAll() }
        .sheet(isPresented: $showingNewProfileSheet) {
            NewVoiceprintProfileSheet(model: model, hasOwner: profiles.contains(where: \.isOwner)) { created in
                Task {
                    await reloadAll()
                    recordingProfile = created
                }
            }
        }
        .sheet(item: $recordingProfile) { profile in
            MacVoiceprintEnrollSheet(model: model, profile: profile) { banner in
                statusBanner = banner
                Task { await reloadAll() }
            }
        }
        .sheet(item: $editingProfile) { profile in
            EditVoiceprintProfileSheet(model: model, profile: profile) {
                Task { await reloadAll() }
            }
        }
    }

    private var engineStatusSection: some View {
        Section {
            let hostReady = model.speechHost.isRunning
            let eng = txStatus?.engine
            LabeledContent("Apple Core ML 加速引擎") {
                HStack(spacing: 6) {
                    Circle()
                        .fill((eng?.reachable == true || hostReady) ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text((eng?.reachable == true || hostReady) ? "运行中（ANE + GPU）" : "未启动")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("核心模型包") {
                HStack(spacing: 8) {
                    modelPill("Silero VAD", ready: eng?.sileroAvailable ?? model.speechHost.status?.sileroAvailable ?? false)
                    modelPill("MOSS 0.9B", ready: eng?.mossAvailable ?? model.speechHost.status?.mossAvailable ?? false)
                    modelPill("ReDimNet2+", ready: eng?.redimnetAvailable ?? model.speechHost.status?.redimnetAvailable ?? false)
                }
            }
            if let q = txStatus?.queue {
                LabeledContent("转录队列") {
                    Text("待处理 \(q.pending) · 处理中 \(q.processing) · 已完成 \(q.done) · 静音跳过 \(q.silent)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let st = txStatus?.storage {
                LabeledContent("Mac 原音缓存") {
                    Text("\(st.chunkCount) 段 · \(String(format: "%.1f MB", st.totalMb))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("刷新状态") { Task { await reloadAll() } }
                    .disabled(loading)
                Button("释放模型内存") {
                    model.speechHost.unloadHeavyModels()
                    statusBanner = "已释放 Core ML 模型内存，下次收到新录音时自动按需加载。"
                }
                Spacer()
                if let busyMessage {
                    ProgressView().controlSize(.small)
                    Text(busyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let statusBanner {
                Text(statusBanner).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(MoMoPalette.failure)
            }
        } header: {
            Text("Mac 转录后端（单通道 Core ML）")
        } footer: {
            Text("Apple Watch 与蓝牙耳机录音由 iPhone 静默中转至 Mac，统一由本机 Core ML 引擎完成转录与说话人识别。")
        }
    }

    private var voiceprintRosterSection: some View {
        Section {
            if profiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("尚未录入声纹")
                        .font(.callout.weight(.medium))
                    Text("先花 15 秒录下「我」的声音，之后所有日常录音都会自动标记你的发言。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("录入我的声音（推荐）") {
                        Task { await quickCreateOwner() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(profiles) { profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: profile.isOwner ? "person.crop.circle.badge.checkmark" : "person.wave.2")
                                .foregroundStyle(profile.isOwner ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(profile.name)
                                        .font(.callout.weight(.medium))
                                    if profile.isOwner {
                                        Text("主人")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 5.5)
                                            .padding(.vertical, 1)
                                            .foregroundStyle(MoMoPalette.success)
                                            .background(MoMoPalette.successBackground, in: Capsule())
                                    }
                                    if !profile.aliases.isEmpty {
                                        Text(profile.aliases.joined(separator: " / "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text("\(profile.sampleCount) 条声纹样本 · 共 \(String(format: "%.1f", profile.totalCleanSeconds))s 清晰语音"
                                     + (profile.rejectionCount > 0 ? " · \(profile.rejectionCount) 条排除样本" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("录制样本") { recordingProfile = profile }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("导入音频") { importAudioSample(for: profile) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("编辑") { editingProfile = profile }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }

                        if !profile.samples.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(profile.samples.prefix(6)) { sample in
                                    HStack(spacing: 4) {
                                        if sample.hasClip {
                                            Button {
                                                Task { await playSampleClip(profileID: profile.id, sampleID: sample.id) }
                                            } label: {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.caption)
                                            }
                                            .buttonStyle(.plain)
                                            .help("试听声纹片段")
                                        }
                                        Text("\(String(format: "%.1fs", sample.cleanSeconds)) · \(sample.sourceDevice)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Button {
                                            Task { await deleteSample(profileID: profile.id, sampleID: sample.id) }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("删除此样本")
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(MoMoPalette.ink.opacity(0.05), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            HStack {
                Button("添加人物") { showingNewProfileSheet = true }
                if !profiles.contains(where: \.isOwner) {
                    Button("锁定我的声音") { Task { await quickCreateOwner() } }
                }
                Spacer()
                Button("重新匹配全部历史录音") {
                    Task { await triggerRematch() }
                }
                .disabled(profiles.isEmpty || busyMessage != nil)
            }
        } header: {
            Text("人物与声纹名册（ReDimNet2+ 192-d）")
        } footer: {
            Text("名册中的人名与别名会自动作为热词注入 MOSS 转录模型，同时用于声纹自动锁定与毫秒级历史回填。")
        }
    }

    private var speechSettingsSection: some View {
        Section("转录参数（手机端可远程同步修改）") {
            Toggle("暂停 Mac 后台转录", isOn: Binding(
                get: { settings.paused },
                set: { val in
                    settings.paused = val
                    Task { await saveSettings() }
                }
            ))
            Picker("主要语言提示", selection: Binding(
                get: { settings.languageHint },
                set: { val in
                    settings.languageHint = val
                    Task { await saveSettings() }
                }
            )) {
                Text("自动（多语混合）").tag("auto")
                Text("中文").tag("中文")
                Text("English").tag("English")
                Text("日本語").tag("日本語")
                Text("한국어").tag("한국어")
            }
            HStack {
                Text("VAD 语音检测灵敏度")
                Spacer()
                Slider(value: $settings.vadThreshold, in: 0.15...0.85, step: 0.05)
                    .frame(width: 180)
                Text(String(format: "%.2f", settings.vadThreshold))
                    .font(.callout.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text("声纹锁定阈值")
                Spacer()
                Slider(value: $settings.speakerLockThreshold, in: 0.40...0.80, step: 0.02)
                    .frame(width: 180)
                Text(String(format: "%.2f", settings.speakerLockThreshold))
                    .font(.callout.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            Stepper("原音保留天数：\(settings.audioRetentionDays) 天", value: $settings.audioRetentionDays, in: 1...365)
            VStack(alignment: .leading, spacing: 4) {
                Text("自定义专有热词（逗号分隔，自动与声纹名册合并）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("例如：MoMo Agent, Core ML, ReDimNet2", text: $hotwordsText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("保存参数") { Task { await saveSettings() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func modelPill(_ name: String, ready: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption2)
                .foregroundStyle(ready ? Color.green : Color.secondary)
            Text(name)
                .font(.caption)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(MoMoPalette.ink.opacity(0.05), in: Capsule())
    }

    private func reloadAll() async {
        loading = true; error = nil
        defer { loading = false }
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

    private func saveSettings() async {
        busyMessage = "正在保存设置…"; error = nil
        defer { busyMessage = nil }
        settings.customHotwords = hotwordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            settings = try await model.updateSpeechSettings(settings)
            hotwordsText = settings.customHotwords.joined(separator: ", ")
            statusBanner = "已更新 Mac 转录设置。"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func quickCreateOwner() async {
        busyMessage = "正在创建「我」的声纹档案…"; error = nil
        defer { busyMessage = nil }
        do {
            let owner = try await model.createVoiceprintProfile(name: "我", isOwner: true, aliases: [])
            await reloadAll()
            recordingProfile = owner
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func importAudioSample(for profile: VoiceprintProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        panel.message = "选择一段 2–60 秒的清晰单人语音，导入为「\(profile.name)」的声纹样本"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busyMessage = "正在提取 ReDimNet2+ 声纹向量…"; error = nil
            defer { busyMessage = nil }
            do {
                let data = try Data(contentsOf: url)
                let res = try await model.enrollVoiceprintSample(
                    profileID: profile.id,
                    audioData: data,
                    filename: url.lastPathComponent,
                    sourceDevice: "mac_import"
                )
                statusBanner = "已导入「\(profile.name)」声纹（清晰语音 \(String(format: "%.1fs", res.quality.cleanSeconds ?? 0))，回填 \(res.rematch.updatedSpans) 段）"
                await reloadAll()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func deleteSample(profileID: String, sampleID: String) async {
        do {
            try await model.deleteVoiceprintSample(profileID: profileID, sampleID: sampleID)
            await reloadAll()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func playSampleClip(profileID: String, sampleID: String) async {
        do {
            let data = try await model.fetchVoiceprintSampleAudio(profileID: profileID, sampleID: sampleID)
            let p = try AVAudioPlayer(data: data)
            p.play()
            clipPlayer = p
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func triggerRematch() async {
        busyMessage = "正在回填历史录音…"; error = nil
        defer { busyMessage = nil }
        do {
            let res = try await model.rematchVoiceprints()
            statusBanner = "扫描 \(res.scannedClusters) 个说话人聚类，更新 \(res.updatedSpans) 条历史转录（耗时 \(String(format: "%.1f", res.elapsedMs)) ms）"
            await model.loadContext(silent: true)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct NewVoiceprintProfileSheet: View {
    let model: DesktopModel
    let hasOwner: Bool
    let onCreated: (VoiceprintProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isOwner = false
    @State private var aliasesText = ""
    @State private var memoryFile = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加声纹人物").font(.headline)
            Form {
                TextField("姓名（例如：张三、Alex）", text: $name)
                if !hasOwner {
                    Toggle("设为主人「我」", isOn: $isOwner)
                }
                TextField("别名 / 常用称呼（逗号分隔，自动作为热词）", text: $aliasesText)
                TextField("关联记忆文件（可选，如 people/alex.md）", text: $memoryFile)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(MoMoPalette.failure) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("下一步：录制声纹") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || (!isOwner && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(18)
        .frame(width: 400, height: 290)
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let mem = memoryFile.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let prof = try await model.createVoiceprintProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isOwner ? "我" : name.trimmingCharacters(in: .whitespacesAndNewlines),
                isOwner: isOwner,
                aliases: aliases,
                memoryFile: mem.isEmpty ? nil : mem
            )
            dismiss()
            onCreated(prof)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct EditVoiceprintProfileSheet: View {
    let model: DesktopModel
    let profile: VoiceprintProfile
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var isOwner: Bool
    @State private var aliasesText: String
    @State private var memoryFile: String
    @State private var notes: String
    @State private var error: String?
    @State private var busy = false

    init(model: DesktopModel, profile: VoiceprintProfile, onSaved: @escaping () -> Void) {
        self.model = model
        self.profile = profile
        self.onSaved = onSaved
        _name = State(initialValue: profile.name)
        _isOwner = State(initialValue: profile.isOwner)
        _aliasesText = State(initialValue: profile.aliases.joined(separator: ", "))
        _memoryFile = State(initialValue: profile.memoryFile ?? "")
        _notes = State(initialValue: profile.notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑声纹人物").font(.headline)
            Form {
                TextField("姓名", text: $name)
                Toggle("这是我本人", isOn: $isOwner)
                TextField("别名 / 热词（逗号分隔）", text: $aliasesText)
                TextField("关联记忆文件（如 people/alex.md）", text: $memoryFile)
                TextField("备注", text: $notes)
            }
            .formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(MoMoPalette.failure) }
            HStack {
                Button("删除人物", role: .destructive) {
                    Task {
                        busy = true
                        defer { busy = false }
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
                Button("保存") {
                    Task {
                        busy = true; error = nil
                        defer { busy = false }
                        let aliases = aliasesText
                            .split(whereSeparator: { $0 == "," || $0 == "，" })
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        let mem = memoryFile.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            _ = try await model.updateVoiceprintProfile(
                                id: profile.id,
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                isOwner: isOwner,
                                aliases: aliases,
                                memoryFile: mem,
                                notes: notes
                            )
                            onSaved()
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420, height: 340)
    }
}

private struct MacVoiceprintEnrollSheet: View {
    let model: DesktopModel
    let profile: VoiceprintProfile
    let onEnrolled: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var recorder = MacVoiceprintRecorder()
    @State private var uploading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("录制「\(profile.name)」的声纹样本")
                .font(.headline)

            Text("请在安静环境下自然朗读下面这句话（约 10–15 秒）：")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("“你好，我是\(profile.name)。今天天气不错，我们待会儿开会讨论一下项目的进展和接下来的安排。”")
                .font(.system(size: 14))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MoMoPalette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                ProgressView(value: Double(recorder.level), total: 1.0)
                    .frame(width: 160)
                Text(String(format: "%.1f 秒", recorder.elapsedSeconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if recorder.isRecording {
                    Button("停止并提取声纹") {
                        Task { await finishRecording() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.elapsedSeconds < 2.2 || uploading)
                } else {
                    Button("开始录音") { recorder.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(uploading)
                }
            }

            if uploading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在通过 ReDimNet2+ Core ML 提取声纹并回填历史记录…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let err = error ?? recorder.error {
                Text(err).font(.caption).foregroundStyle(MoMoPalette.failure)
            }

            HStack {
                Spacer()
                Button("关闭") {
                    recorder.cancel()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .onDisappear { recorder.cancel() }
    }

    private func finishRecording() async {
        guard let data = recorder.stopAndReadData() else {
            error = "未录到有效音频，请重试。"
            return
        }
        uploading = true; error = nil
        defer { uploading = false }
        do {
            let res = try await model.enrollVoiceprintSample(
                profileID: profile.id,
                audioData: data,
                filename: "mac-mic.wav",
                sourceDevice: "mac_mic"
            )
            onEnrolled("已录入「\(profile.name)」声纹（清晰语音 \(String(format: "%.1fs", res.quality.cleanSeconds ?? 0))，已回填 \(res.rematch.updatedSpans) 条历史记录）")
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
