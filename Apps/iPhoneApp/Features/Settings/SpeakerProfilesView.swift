import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import MoMoAgentClient
import MoMoArchive

private final class SampleClipPlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var onFinish: (@Sendable () -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

/// Clean AI-native People & Voiceprints screen on iPhone.
struct SpeakerProfilesView: View {
    let archive: ArchiveStore
    var remoteAgent: PhoneRemoteAgent? = nil
    var uploader: AudioUploadCoordinator? = nil
    var onSpeakersChanged: (() async -> Void)? = nil

    @State private var macProfiles: [VoiceprintProfile] = []
    @State private var localPeople: [SpeakerProfile] = []
    @State private var loaded = false
    @State private var rematching = false
    @State private var rematchMessage: String?
    @State private var failure: String?

    @State private var showingOnboarding = false
    @State private var showingNewPerson = false
    @State private var selectedProfile: VoiceprintProfile?
    @State private var deletingMacProfile: VoiceprintProfile?

    @State private var loadingPlayID: String?
    @State private var playingProfileID: String?
    @State private var listPlayer: AVAudioPlayer?
    @State private var listPlayerDelegate = SampleClipPlayerDelegate()

    private var isConnectedToMac: Bool { remoteAgent?.speechDataClient != nil }
    private var ownerProfile: VoiceprintProfile? { macProfiles.first(where: \.isOwner) }
    private var sortedProfiles: [VoiceprintProfile] {
        macProfiles.sorted { ($0.isOwner ? 0 : 1) < ($1.isOwner ? 0 : 1) }
    }

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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingOnboarding = true
                        } label: {
                            Label("录下我的声音", systemImage: "mic")
                        }
                        .accessibilityIdentifier("speaker.owner.onboarding")

                        if !macProfiles.isEmpty {
                            Button {
                                Task { await runGlobalRematch() }
                            } label: {
                                Label("重新匹配历史录音", systemImage: "waveform.badge.magnifyingglass")
                            }
                            .disabled(rematching)
                            .accessibilityIdentifier("speaker.rematch.all")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多")
                    .accessibilityIdentifier("speaker.more.menu")

                    Button {
                        showingNewPerson = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加人物")
                    .accessibilityIdentifier("speaker.add.person")
                }
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onDisappear { stopListPlayback() }
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
                        onSkip: nil
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
            if let remoteAgent, let client = remoteAgent.speechDataClient {
                MacVoiceprintPersonDetailSheet(
                    remoteAgent: remoteAgent,
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
            "删除人物？",
            isPresented: Binding(get: { deletingMacProfile != nil }, set: { if !$0 { deletingMacProfile = nil } }),
            titleVisibility: .visible,
            presenting: deletingMacProfile
        ) { person in
            Button("删除 \(person.name)", role: .destructive) {
                Task { await deleteMacProfile(person) }
            }
        } message: { _ in
            Text("保留原始录音与文字。")
        }
        .alert("操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    @ViewBuilder
    private var macRosterContent: some View {
        if ownerProfile == nil || (ownerProfile?.sampleCount ?? 0) == 0 {
            Section {
                Button {
                    showingOnboarding = true
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(MoMoPalette.successBackground)
                            .frame(width: 34, height: 34)
                            .overlay {
                                Image(systemName: "waveform")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(MoMoPalette.success)
                            }
                        Text("录下我的声音")
                            .fontWeight(.medium)
                            .foregroundStyle(MoMoPalette.ink)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("speaker.owner.onboarding")
            }
        }

        Section {
            if sortedProfiles.isEmpty && loaded {
                Text("暂无人物")
                    .foregroundStyle(MoMoPalette.muted)
            } else {
                ForEach(sortedProfiles) { person in
                    rosterRow(person)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deletingMacProfile = person
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
        } footer: {
            if rematching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在匹配…")
                }
            } else if let rematchMessage {
                Text(rematchMessage)
            }
        }
    }

    private func rosterRow(_ person: VoiceprintProfile) -> some View {
        let firstClip = person.samples.first(where: \.hasClip)
        let isPlaying = (playingProfileID == person.id)
        return HStack(spacing: 12) {
            Button {
                stopListPlayback()
                selectedProfile = person
            } label: {
                HStack(spacing: 12) {
                    Circle()
                        .fill(person.isOwner ? MoMoPalette.successBackground : MoMoPalette.ink.opacity(0.07))
                        .frame(width: 34, height: 34)
                        .overlay {
                            Text(String(person.name.prefix(1)))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(person.isOwner ? MoMoPalette.success : MoMoPalette.ink)
                        }
                    HStack(spacing: 6) {
                        Text(person.name)
                            .foregroundStyle(MoMoPalette.ink)
                        if person.isOwner {
                            Text("本人")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(MoMoPalette.successBackground, in: Capsule())
                                .foregroundStyle(MoMoPalette.success)
                        }
                    }
                    Spacer(minLength: 8)
                    if person.sampleCount > 0 {
                        Text(String(format: "%.0fs", max(1, person.totalCleanSeconds)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("未录")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let sample = firstClip {
                Button {
                    Task { await toggleListPlay(profile: person, sample: sample) }
                } label: {
                    Group {
                        if loadingPlayID == person.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                                .font(.title3)
                                .foregroundStyle(isPlaying ? MoMoPalette.success : MoMoPalette.muted)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "停止试听" : "试听\(person.name)")
                .accessibilityIdentifier("speaker.row.play.\(person.id)")
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var offlineContent: some View {
        Section {
            Label("连接 Mac 后可管理声纹", systemImage: "desktopcomputer")
                .foregroundStyle(MoMoPalette.muted)
        }
        if !localPeople.isEmpty {
            Section {
                ForEach(localPeople) { person in
                    Text(person.name)
                }
            }
        }
    }

    private func toggleListPlay(profile: VoiceprintProfile, sample: VoiceprintSample) async {
        guard let client = remoteAgent?.speechDataClient else { return }
        if playingProfileID == profile.id {
            stopListPlayback()
            return
        }
        stopListPlayback()
        loadingPlayID = profile.id
        defer { if loadingPlayID == profile.id { loadingPlayID = nil } }
        do {
            let data = try await client.fetchVoiceprintSampleAudio(profileID: profile.id, sampleID: sample.id)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            let pid = profile.id
            listPlayerDelegate.onFinish = {
                Task { @MainActor in
                    if playingProfileID == pid {
                        stopListPlayback()
                    }
                }
            }
            player.delegate = listPlayerDelegate
            guard player.play() else { return }
            listPlayer = player
            playingProfileID = profile.id
        } catch {
            failure = error.localizedDescription
        }
    }

    private func stopListPlayback() {
        listPlayer?.stop()
        listPlayer = nil
        if playingProfileID != nil {
            playingProfileID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        stopListPlayback()
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
            rematchMessage = String(format: "已匹配 %d 处（%.1f ms）", summary.updatedSpans, summary.elapsedMs)
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
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("姓名", text: $name)
                        .textContentType(.name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit { Task { await create() } }
                    TextField("别名（可选，逗号分隔）", text: $aliasesText)
                }
                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(MoMoPalette.failure)
                    }
                }
            }
            .navigationTitle("添加人物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { Task { await create() } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.height(260), .medium])
    }

    private func create() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true; error = nil
        defer { saving = false }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let profile = try await client.createVoiceprintProfile(name: trimmed, isOwner: false, aliases: aliases)
            onCreated(profile)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct MacVoiceprintPersonDetailSheet: View {
    let remoteAgent: PhoneRemoteAgent
    let client: AgentClient
    @State var profile: VoiceprintProfile
    let onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var aliasesText: String = ""
    @State private var notes: String = ""
    @State private var saving = false
    @State private var importingFile = false
    @State private var showingRecorder = false
    @State private var statusBanner: String?
    @State private var error: String?
    @State private var loadingSampleID: String?
    @State private var playingSampleID: String?
    @State private var samplePlayer: AVAudioPlayer?
    @State private var playerDelegate = SampleClipPlayerDelegate()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("姓名") {
                        TextField("姓名", text: $name)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit { Task { await saveProfileInfoIfDirty() } }
                    }
                    LabeledContent("别名") {
                        TextField("逗号分隔", text: $aliasesText)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit { Task { await saveProfileInfoIfDirty() } }
                    }
                    LabeledContent("备注") {
                        TextField("可选", text: $notes)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit { Task { await saveProfileInfoIfDirty() } }
                    }
                }

                Section("声音") {
                    ForEach(profile.samples) { sample in
                        HStack(spacing: 12) {
                            if sample.hasClip {
                                Button {
                                    Task { await toggleSamplePlayback(sample) }
                                } label: {
                                    Group {
                                        if loadingSampleID == sample.id {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: playingSampleID == sample.id ? "stop.circle.fill" : "play.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(playingSampleID == sample.id ? MoMoPalette.success : MoMoPalette.ink)
                                        }
                                    }
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(playingSampleID == sample.id ? "停止试听" : "试听")
                                .accessibilityIdentifier("voiceprint.sample.play.\(sample.id)")
                                .disabled(loadingSampleID != nil && loadingSampleID != sample.id)
                            }
                            Text(String(format: "%.1fs", sample.cleanSeconds))
                                .monospacedDigit()
                            Spacer()
                            Text(friendlySource(sample))
                                .font(.caption)
                                .foregroundStyle(MoMoPalette.muted)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await deleteSample(sample) }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }

                    Button {
                        stopSamplePlayback()
                        showingRecorder = true
                    } label: {
                        Label("录制一段", systemImage: "mic")
                    }
                    .disabled(saving)

                    Button {
                        importingFile = true
                    } label: {
                        Label("导入音频", systemImage: "square.and.arrow.down")
                    }
                    .disabled(saving)

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
            }
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            await saveProfileInfoIfDirty()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                name = profile.name
                aliasesText = profile.aliases.joined(separator: ", ")
                notes = profile.notes
            }
            .onDisappear { stopSamplePlayback() }
            .sheet(isPresented: $showingRecorder) {
                NavigationStack {
                    VoiceprintOnboardingView(
                        remoteAgent: remoteAgent,
                        targetProfile: profile,
                        onFinish: {
                            showingRecorder = false
                            Task {
                                if let fresh = try? await client.voiceprintProfiles().first(where: { $0.id == profile.id }) {
                                    profile = fresh
                                }
                                await onChanged()
                            }
                        },
                        onSkip: nil
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { showingRecorder = false }
                        }
                    }
                }
            }
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

    private func friendlySource(_ s: VoiceprintSample) -> String {
        if s.sourceKind == "transcript_bind" || s.sourceKind == "transcript_confirm" { return "录音" }
        if s.sourceDevice.contains("iphone") { return "iPhone" }
        if s.sourceDevice.contains("mac") { return "Mac" }
        return "导入"
    }

    private func saveProfileInfoIfDirty() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let aliases = aliasesText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard trimmed != profile.name || aliases != profile.aliases || notes != profile.notes else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            profile = try await client.updateVoiceprintProfile(
                id: profile.id,
                name: trimmed,
                isOwner: profile.isOwner,
                aliases: aliases,
                memoryFile: profile.memoryFile,
                notes: notes
            )
            await onChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func uploadAudioFile(_ url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let rawData = try? Data(contentsOf: url), !rawData.isEmpty else {
            error = "无法读取音频文件。"
            return
        }
        // Keep voiceprint imports strictly below Relay's 512 KB request limit by transcoding
        // oversized files (>460 KB) into compact 16 kHz mono AAC (up to 60s -> ~180 KB).
        if rawData.count > 460 * 1024 {
            saving = true; error = nil; statusBanner = nil
            do {
                let transcoded = try await AudioUploadCoordinator.transcodeVoiceprintClipToRelaySafeAAC(
                    sourceURL: url,
                    maxDurationSeconds: 60.0
                )
                saving = false
                await enrollBytes(transcoded, filename: "iphone-import.m4a", device: "iphone_import")
            } catch {
                saving = false
                self.error = error.localizedDescription
            }
            return
        }
        await enrollBytes(rawData, filename: url.lastPathComponent, device: "iphone_import")
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
            statusBanner = res.rematch.updatedSpans > 0 ? "已记住 · 更新 \(res.rematch.updatedSpans) 处" : "已记住"
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

    private func toggleSamplePlayback(_ sample: VoiceprintSample) async {
        if playingSampleID == sample.id {
            stopSamplePlayback()
            return
        }
        stopSamplePlayback()
        loadingSampleID = sample.id
        error = nil
        defer { if loadingSampleID == sample.id { loadingSampleID = nil } }
        do {
            let data = try await client.fetchVoiceprintSampleAudio(profileID: profile.id, sampleID: sample.id)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: data)
            let sampleID = sample.id
            playerDelegate.onFinish = {
                Task { @MainActor in
                    if playingSampleID == sampleID {
                        playingSampleID = nil
                        samplePlayer = nil
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                    }
                }
            }
            player.delegate = playerDelegate
            guard player.play() else {
                error = "无法播放音频。"
                return
            }
            samplePlayer = player
            playingSampleID = sample.id
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stopSamplePlayback() {
        samplePlayer?.stop()
        samplePlayer = nil
        if playingSampleID != nil {
            playingSampleID = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
