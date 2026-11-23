import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient
import MoMoArchive

/// iPhone Speaker Voiceprint Roster screen.
///
/// When connected to Mac (`remoteAgent?.speechDataClient != nil`), manages Mac's authoritative
/// ReDimNet2+ voiceprint roster: owner voiceprint onboarding, adding people, recording or importing
/// reference voice clips, managing aliases/hotwords, and triggering <100ms global history rematch.
struct SpeakerProfilesView: View {
    let archive: ArchiveStore
    var remoteAgent: PhoneRemoteAgent? = nil
    var uploader: AudioUploadCoordinator? = nil
    var onSpeakersChanged: (() async -> Void)? = nil

    @State private var macProfiles: [VoiceprintProfile] = []
    @State private var localPeople: [SpeakerProfile] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var rematching = false
    @State private var rematchMessage: String?
    @State private var failure: String?

    @State private var showingOnboarding = false
    @State private var showingNewPerson = false
    @State private var selectedProfile: VoiceprintProfile?
    @State private var deletingMacProfile: VoiceprintProfile?

    private var isConnectedToMac: Bool { remoteAgent?.speechDataClient != nil }
    private var ownerProfile: VoiceprintProfile? { macProfiles.first(where: \.isOwner) }

    var body: some View {
        List {
            if isConnectedToMac {
                macRosterContent
            } else {
                offlineContent
            }
        }
        .overlay {
            if !loaded && failure == nil { ProgressView() }
        }
        .buttonStyle(.automatic)
        .phoneSoftTopEdge()
        .navigationTitle("人物与声纹")
        .navigationBarTitleDisplayMode(.inline)
        .tint(MoMoPalette.ink)
        .toolbar {
            if isConnectedToMac {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewPerson = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("新增声纹人物")
                    .accessibilityIdentifier("speaker.add.person")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(isPresented: $showingOnboarding) {
            if let remoteAgent {
                NavigationStack {
                    VoiceprintOnboardingView(
                        remoteAgent: remoteAgent,
                        onFinish: {
                            showingOnboarding = false
                            Task {
                                await reload()
                                await uploader?.syncRemoteTranscriptsFromMac(force: true)
                                await onSpeakersChanged?()
                            }
                        },
                        onSkip: { showingOnboarding = false }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showingOnboarding = false }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingNewPerson) {
            if let client = remoteAgent?.speechDataClient {
                MacNewVoiceprintPersonSheet(client: client) { created in
                    showingNewPerson = false
                    Task {
                        await reload()
                        selectedProfile = created
                    }
                }
            }
        }
        .sheet(item: $selectedProfile) { profile in
            if let client = remoteAgent?.speechDataClient {
                MacVoiceprintPersonDetailSheet(
                    client: client,
                    profile: profile,
                    onChanged: {
                        await reload()
                        await uploader?.syncRemoteTranscriptsFromMac(force: true)
                        await onSpeakersChanged?()
                    }
                )
            }
        }
        .confirmationDialog(
            "删除人物与声纹？",
            isPresented: Binding(get: { deletingMacProfile != nil }, set: { if !$0 { deletingMacProfile = nil } }),
            titleVisibility: .visible,
            presenting: deletingMacProfile
        ) { person in
            Button("删除 \(person.name)", role: .destructive) {
                Task { await deleteMacProfile(person) }
            }
        } message: { _ in
            Text("清除 Mac 端该人物的声纹样本与绑定，保留原始录音和转录文字。")
        }
        .alert("声纹操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    @ViewBuilder
    private var macRosterContent: some View {
        Section {
            Button {
                showingOnboarding = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ownerProfile?.sampleCount ?? 0 > 0 ? "person.crop.circle.badge.checkmark" : "person.wave.2.fill")
                        .font(.title2)
                        .foregroundStyle(ownerProfile?.sampleCount ?? 0 > 0 ? MoMoPalette.success : MoMoPalette.ink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ownerProfile?.sampleCount ?? 0 > 0 ? "补录我的声音（提升跨设备准确度）" : "锁定我的声音（15 秒引导）")
                            .foregroundStyle(MoMoPalette.ink)
                            .fontWeight(.medium)
                        if let owner = ownerProfile, owner.sampleCount > 0 {
                            Text(String(format: "已录入 %d 条样本 · %.1f 秒清晰语音", owner.sampleCount, owner.totalCleanSeconds))
                                .font(.caption)
                                .foregroundStyle(MoMoPalette.muted)
                        } else {
                            Text("录入后，Watch / 耳机 / 电脑录音将自动标出「我」")
                                .font(.caption)
                                .foregroundStyle(MoMoPalette.muted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("speaker.owner.onboarding")
        } header: {
            Text("我的声纹")
        }

        Section {
            if macProfiles.isEmpty && loaded {
                Text("还没有其他人物。点右上角 + 提前录入同事/家人，或在转录里点任意说话人一键绑定。")
                    .font(.footnote)
                    .foregroundStyle(MoMoPalette.muted)
            } else {
                ForEach(macProfiles) { person in
                    Button {
                        selectedProfile = person
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: person.isOwner ? "person.crop.circle.fill" : "person.crop.circle")
                                .font(.title2)
                                .foregroundStyle(person.isOwner ? MoMoPalette.success : MoMoPalette.muted)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(person.name)
                                        .foregroundStyle(MoMoPalette.ink)
                                    if person.isOwner {
                                        Text("主人")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(MoMoPalette.successBackground, in: Capsule())
                                            .foregroundStyle(MoMoPalette.success)
                                    }
                                }
                                Text(String(format: "样本 %d · %.1f 秒 · 排除 %d", person.sampleCount, person.totalCleanSeconds, person.rejectionCount))
                                    .font(.caption)
                                    .foregroundStyle(MoMoPalette.muted)
                                    .monospacedDigit()
                                if !person.aliases.isEmpty {
                                    Text("别名：\(person.aliases.joined(separator: "、"))")
                                        .font(.caption2)
                                        .foregroundStyle(MoMoPalette.muted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deletingMacProfile = person
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Mac 声纹名册（ReDimNet2+ Core ML）")
        } footer: {
            Text("点击人物可查看/删除声纹片段、用麦克风补录、导入参考音频或设置别名热词。")
        }

        if !macProfiles.isEmpty {
            Section {
                Button {
                    Task { await runGlobalRematch() }
                } label: {
                    HStack {
                        if rematching {
                            ProgressView().controlSize(.small)
                            Text("正在 Mac 端重匹配历史声纹…")
                        } else {
                            Label("立即重匹配全部历史录音", systemImage: "waveform.badge.magnifyingglass")
                                .foregroundStyle(MoMoPalette.ink)
                        }
                    }
                }
                .disabled(rematching || busy)
                .accessibilityIdentifier("speaker.rematch.all")
            } footer: {
                if let rematchMessage {
                    Label(rematchMessage, systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(MoMoPalette.muted)
                } else {
                    Text("只重新比对 192 维声纹向量，无需重新转录，通常在 100 毫秒内完成。")
                }
            }
        }
    }

    @ViewBuilder
    private var offlineContent: some View {
        Section {
            Label("请先配对并连接 Mac，即可管理全局 ReDimNet2+ 声纹名册、录入声纹样本并毫秒级重匹配历史录音。", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(MoMoPalette.muted)
        }
        if !localPeople.isEmpty {
            Section("本机缓存的说话人") {
                ForEach(localPeople) { person in
                    HStack {
                        Text(person.name)
                        Spacer()
                        Text("样本 \(person.sampleCount)")
                            .font(.caption)
                            .foregroundStyle(MoMoPalette.muted)
                    }
                }
            }
        }
    }

    private func reload() async {
        if let client = remoteAgent?.speechDataClient {
            do {
                macProfiles = try await client.voiceprintProfiles()
                loaded = true
                return
            } catch {
                failure = error.localizedDescription
            }
        }
        do {
            localPeople = try await archive.speakerProfiles()
            loaded = true
        } catch {
            failure = error.localizedDescription
            loaded = true
        }
    }

    private func deleteMacProfile(_ profile: VoiceprintProfile) async {
        guard let client = remoteAgent?.speechDataClient else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.deleteVoiceprintProfile(id: profile.id)
            await reload()
            await uploader?.syncRemoteTranscriptsFromMac(force: true)
            await onSpeakersChanged?()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func runGlobalRematch() async {
        guard let client = remoteAgent?.speechDataClient else { return }
        rematching = true
        rematchMessage = nil
        defer { rematching = false }
        do {
            let summary = try await client.rematchVoiceprints()
            rematchMessage = String(
                format: "已扫描 %d 个声纹簇，更新 %d 条语音（耗时 %.1f ms）。",
                summary.scannedClusters,
                summary.updatedSpans,
                summary.elapsedMs
            )
            await uploader?.syncRemoteTranscriptsFromMac(force: true)
            await onSpeakersChanged?()
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct MacNewVoiceprintPersonSheet: View {
    let client: AgentClient
    let onCreated: (VoiceprintProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aliasesText = ""
    @State private var isOwner = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("姓名（例如：Alex、产品经理）", text: $name)
                        .textContentType(.name)
                    TextField("别名 / 称呼（逗号分隔，自动注入热词）", text: $aliasesText)
                    Toggle("设为设备主人（「我」）", isOn: $isOwner)
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(MoMoPalette.failure)
                    }
                }
            }
            .navigationTitle("新增声纹人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task { await create() }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true; error = nil
        defer { saving = false }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let profile = try await client.createVoiceprintProfile(name: trimmed, isOwner: isOwner, aliases: aliases)
            onCreated(profile)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MacVoiceprintPersonDetailSheet: View {
    let client: AgentClient
    @State var profile: VoiceprintProfile
    let onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var aliasesText: String = ""
    @State private var notes: String = ""
    @State private var saving = false
    @State private var importingFile = false
    @State private var recording = false
    @State private var recordSeconds: Double = 0
    @State private var recorder: AVAudioRecorder?
    @State private var recordURL: URL?
    @State private var timerTask: Task<Void, Never>?
    @State private var statusBanner: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("资料与热词") {
                    TextField("姓名", text: $name)
                    TextField("别名（逗号分隔，自动注入热词）", text: $aliasesText)
                    TextField("备注（角色 / 关系）", text: $notes)
                    Button {
                        Task { await saveProfileInfo() }
                    } label: {
                        if saving { ProgressView() } else { Text("保存修改") }
                    }
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("补充声纹样本") {
                    if recording {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(String(format: "正在录音 %.1f 秒（建议 5–15 秒）", recordSeconds))
                                .monospacedDigit()
                            Spacer()
                            Button("停止并录入") {
                                Task { await stopRecordingAndUpload() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(recordSeconds < 2.0)
                        }
                    } else {
                        Button {
                            Task { await startRecording() }
                        } label: {
                            Label("用手机麦克风录制一段", systemImage: "mic.fill")
                        }
                        .disabled(saving)
                        Button {
                            importingFile = true
                        } label: {
                            Label("从文件导入参考音频（wav / m4a / mp3）", systemImage: "square.and.arrow.down")
                        }
                        .disabled(saving)
                    }
                    if let statusBanner {
                        Text(statusBanner)
                            .font(.footnote)
                            .foregroundStyle(MoMoPalette.success)
                    }
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(MoMoPalette.failure)
                    }
                }

                Section("已录入声纹样本（\(profile.samples.count)）") {
                    if profile.samples.isEmpty {
                        Text("还没有声音样本。录制或导入一段 5–15 秒的干净语音，或在转录页点击该说话人勾选「记住 TA 的声音」。")
                            .font(.footnote)
                            .foregroundStyle(MoMoPalette.muted)
                    } else {
                        ForEach(profile.samples) { sample in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text((sample.sourceKind == "transcript_bind" || sample.sourceKind == "transcript_confirm") ? "转录确认收录" : "手动录入 · \(sample.sourceDevice)")
                                        .font(.subheadline)
                                    Text(String(format: "清晰语音 %.1f 秒 · SNR %.0f dB", sample.cleanSeconds, sample.snrDb))
                                        .font(.caption)
                                        .foregroundStyle(MoMoPalette.muted)
                                        .monospacedDigit()
                                }
                                Spacer()
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await deleteSample(sample) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                name = profile.name
                aliasesText = profile.aliases.joined(separator: ", ")
                notes = profile.notes
            }
            .onDisappear { cleanupRecorder() }
            .fileImporter(
                isPresented: $importingFile,
                allowedContentTypes: [.audio, .mpeg4Audio, .wav, .mp3],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                Task { await uploadAudioFile(url) }
            }
        }
    }

    private func saveProfileInfo() async {
        saving = true; error = nil; statusBanner = nil
        defer { saving = false }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            profile = try await client.updateVoiceprintProfile(
                id: profile.id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                isOwner: profile.isOwner,
                aliases: aliases,
                memoryFile: profile.memoryFile,
                notes: notes
            )
            statusBanner = "资料已同步到 Mac。"
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func startRecording() async {
        error = nil; statusBanner = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            error = "请在系统设置中允许使用麦克风。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID().uuidString).m4a")
            let rec = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ])
            guard rec.record() else { error = "无法启动录音。"; return }
            recorder = rec; recordURL = url; recordSeconds = 0; recording = true
            timerTask?.cancel()
            timerTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let r = recorder, r.isRecording else { return }
                    recordSeconds = r.currentTime
                    if r.currentTime >= 30.0 {
                        await self.stopRecordingAndUpload()
                        return
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stopRecordingAndUpload() async {
        timerTask?.cancel(); timerTask = nil
        recorder?.stop(); recorder = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = recordURL else { return }
        recordURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        await enrollBytes(data, filename: "iphone-mic.m4a", device: "iphone_mic")
    }

    private func uploadAudioFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            error = "无法读取选中的音频文件。"
            return
        }
        await enrollBytes(data, filename: url.lastPathComponent, device: "iphone_import")
    }

    private func enrollBytes(_ data: Data, filename: String, device: String) async {
        saving = true; error = nil; statusBanner = nil
        defer { saving = false }
        do {
            let res = try await client.enrollVoiceprintSample(
                profileID: profile.id,
                audioData: data,
                filename: filename,
                sourceDevice: device
            )
            profile = res.profile
            statusBanner = String(
                format: "已录入 %.1f 秒清晰声纹，并重匹配 %d 条历史记录（%.1f ms）。",
                res.quality.cleanSeconds ?? 0,
                res.rematch.updatedSpans,
                res.rematch.elapsedMs
            )
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteSample(_ sample: VoiceprintSample) async {
        saving = true; error = nil
        defer { saving = false }
        do {
            try await client.deleteVoiceprintSample(profileID: profile.id, sampleID: sample.id)
            let updated = try await client.voiceprintProfiles()
            if let fresh = updated.first(where: { $0.id == profile.id }) {
                profile = fresh
            }
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cleanupRecorder() {
        timerTask?.cancel(); timerTask = nil
        recorder?.stop(); recorder = nil; recording = false
        if let url = recordURL { try? FileManager.default.removeItem(at: url); recordURL = nil }
    }
}
