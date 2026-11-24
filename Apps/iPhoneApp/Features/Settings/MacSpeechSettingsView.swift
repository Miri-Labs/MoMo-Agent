import SwiftUI
import MoMoAgentClient

/// Minimal auto-saving iPhone remote settings for Mac transcription.
struct MacSpeechSettingsView: View {
    let remoteAgent: PhoneRemoteAgent
    var uploader: AudioUploadCoordinator?

    @State private var status: MacTranscriptionStatus?
    @State private var settings = MacSpeechSettings()
    @State private var hotwordsText = ""
    @State private var showAdvanced = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        Form {
            statusSection
            if remoteAgent.speechDataClient != nil {
                preferencesSection
                advancedSection
            }
        }
        .navigationTitle("Mac 转录设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .onDisappear {
            if loaded && remoteAgent.speechDataClient != nil {
                Task { await saveIfHotwordsChanged() }
            }
        }
    }

    private var statusSection: some View {
        Section {
            if remoteAgent.speechDataClient == nil {
                Label("请先连接 Mac", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Mac")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(status?.engine?.reachable == true ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(status?.engine?.reachable == true ? "在线" : "连接中")
                            .foregroundStyle(.secondary)
                    }
                }
                if let uploader, uploader.pendingCount > 0 {
                    LabeledContent("同步中") {
                        Text("\(uploader.pendingCount) 段")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(MoMoPalette.failure)
            }
        }
    }

    private var preferencesSection: some View {
        Section {
            Toggle("自动转录", isOn: Binding(
                get: { !settings.paused },
                set: { active in
                    settings.paused = !active
                    Task { await save() }
                }
            ))
            Picker("语言", selection: Binding(
                get: { settings.languageHint },
                set: { val in
                    settings.languageHint = val
                    Task { await save() }
                }
            )) {
                Text("自动").tag("auto")
                Text("中文").tag("中文")
                Text("English").tag("English")
                Text("日本語").tag("日本語")
                Text("한국어").tag("한국어")
            }
            LabeledContent("热词") {
                TextField("逗号分隔", text: $hotwordsText)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("高级", isExpanded: $showAdvanced) {
                Stepper("原音保留 \(settings.audioRetentionDays) 天", value: Binding(
                    get: { settings.audioRetentionDays },
                    set: { val in
                        settings.audioRetentionDays = val
                        Task { await save() }
                    }
                ), in: 1...365)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("语音灵敏度")
                        Spacer()
                        Text(String(format: "%.2f", settings.vadThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.vadThreshold, in: 0.15...0.85, step: 0.05) { editing in
                        if !editing { Task { await save() } }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("声纹严格度")
                        Spacer()
                        Text(String(format: "%.2f", settings.speakerLockThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.speakerLockThreshold, in: 0.40...0.80, step: 0.02) { editing in
                        if !editing { Task { await save() } }
                    }
                }

                if let st = status?.storage {
                    LabeledContent("原音缓存") {
                        Text(String(format: "%.1f MB", st.totalMb))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func reload() async {
        guard let client = remoteAgent.speechDataClient else { return }
        error = nil
        do {
            let st = try await client.transcriptionStatus()
            status = st
            settings = st.settings
            hotwordsText = st.settings.customHotwords.joined(separator: ", ")
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func parsedHotwords() -> [String] {
        hotwordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func saveIfHotwordsChanged() async {
        if parsedHotwords() != settings.customHotwords {
            await save()
        }
    }

    private func save() async {
        guard let client = remoteAgent.speechDataClient else { return }
        error = nil
        settings.customHotwords = parsedHotwords()
        do {
            settings = try await client.updateSpeechSettings(settings)
            hotwordsText = settings.customHotwords.joined(separator: ", ")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
