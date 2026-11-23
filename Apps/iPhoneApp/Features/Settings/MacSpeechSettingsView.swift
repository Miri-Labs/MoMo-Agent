import SwiftUI
import MoMoAgentClient

/// iPhone remote control panel for Mac's CoreML transcription backend (`GET/PATCH /context/v1/speech/settings`).
/// Replaces all legacy on-device iPhone speech model / VAD / segmentation settings.
struct MacSpeechSettingsView: View {
    let remoteAgent: PhoneRemoteAgent
    var uploader: AudioUploadCoordinator?

    @State private var status: MacTranscriptionStatus?
    @State private var settings = MacSpeechSettings()
    @State private var hotwordsText = ""
    @State private var loading = false
    @State private var saving = false
    @State private var savedBanner: String?
    @State private var error: String?

    var body: some View {
        Form {
            statusSection
            if remoteAgent.speechDataClient != nil {
                controlsSection
                hotwordsSection
                retentionSection
            }
        }
        .navigationTitle("Mac 转录设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var statusSection: some View {
        Section {
            if remoteAgent.speechDataClient == nil {
                Label("请先配对并连接 Mac，录音将自动同步到 Mac 使用 Apple Core ML 转录。", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("转录引擎") {
                    Text(status?.engine?.reachable == true ? "Mac Core ML 在线" : "连接检查中")
                        .foregroundStyle(status?.engine?.reachable == true ? MoMoPalette.success : .secondary)
                }
                LabeledContent("核心模型") {
                    Text("MOSS 0.9B + ReDimNet2+")
                        .foregroundStyle(.secondary)
                }
                if let uploader {
                    LabeledContent("手机待上传片段") {
                        Text("\(uploader.pendingCount) 段（已传 \(uploader.uploadedCount)）")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let q = status?.queue {
                    LabeledContent("Mac 处理队列") {
                        Text("待处理 \(q.pending) · 已完成 \(q.done)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let st = status?.storage {
                    LabeledContent("Mac 原音缓存") {
                        Text(String(format: "%.1f MB", st.totalMb))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(MoMoPalette.failure)
            }
            if let savedBanner {
                Text(savedBanner).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Mac 后端状态")
        } footer: {
            Text("iPhone 不再在本地运行耗电的语音模型，仅负责静默中转 Apple Watch 与蓝牙耳机录音。")
        }
    }

    private var controlsSection: some View {
        Section("转录控制") {
            Toggle("暂停 Mac 后台转录", isOn: Binding(
                get: { settings.paused },
                set: { val in
                    settings.paused = val
                    Task { await save() }
                }
            ))
            Picker("主要语言提示", selection: Binding(
                get: { settings.languageHint },
                set: { val in
                    settings.languageHint = val
                    Task { await save() }
                }
            )) {
                Text("自动（多语混合）").tag("auto")
                Text("中文").tag("中文")
                Text("English").tag("English")
                Text("日本語").tag("日本語")
                Text("한국어").tag("한국어")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("VAD 语音检测灵敏度")
                    Spacer()
                    Text(String(format: "%.2f", settings.vadThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.vadThreshold, in: 0.15...0.85, step: 0.05)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("声纹自动锁定阈值")
                    Spacer()
                    Text(String(format: "%.2f", settings.speakerLockThreshold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.speakerLockThreshold, in: 0.40...0.80, step: 0.02)
            }
        }
    }

    private var hotwordsSection: some View {
        Section {
            TextField("例如：MoMo Agent, Core ML, 项目代号", text: $hotwordsText, axis: .vertical)
                .lineLimit(2...4)
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Spacer()
                    if saving { ProgressView() } else { Text("同步保存到 Mac") }
                    Spacer()
                }
            }
            .disabled(saving)
        } header: {
            Text("自定义热词（逗号分隔）")
        } footer: {
            Text("热词会与声纹名册中的人名及别名自动合并，注入 Mac 端 MOSS 模型的转录提示中。")
        }
    }

    private var retentionSection: some View {
        Section("Mac 原音保留策略") {
            Stepper("原音保留 \(settings.audioRetentionDays) 天", value: $settings.audioRetentionDays, in: 1...365)
            Button("保存保留天数") { Task { await save() } }
                .disabled(saving)
        }
    }

    private func reload() async {
        guard let client = remoteAgent.speechDataClient else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let st = try await client.transcriptionStatus()
            status = st
            settings = st.settings
            hotwordsText = st.settings.customHotwords.joined(separator: ", ")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() async {
        guard let client = remoteAgent.speechDataClient else { return }
        saving = true; error = nil; savedBanner = nil
        defer { saving = false }
        settings.customHotwords = hotwordsText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            settings = try await client.updateSpeechSettings(settings)
            hotwordsText = settings.customHotwords.joined(separator: ", ")
            savedBanner = "已同步到 Mac 端。"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
