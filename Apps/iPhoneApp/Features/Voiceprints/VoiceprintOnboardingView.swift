import AVFoundation
import SwiftUI
import MoMoAgentClient

/// Guided ~15-second voiceprint onboarding flow ("锁定我的声音") shown right after Mac pairing
/// and re-openable anytime from「人物与声纹」.
struct VoiceprintOnboardingView: View {
    let remoteAgent: PhoneRemoteAgent
    let onFinish: () -> Void
    var onSkip: (() -> Void)? = nil

    @State private var recording = false
    @State private var elapsed: Double = 0
    @State private var level: Float = 0
    @State private var uploading = false
    @State private var completedSamples = 0
    @State private var lastQualityText: String?
    @State private var error: String?
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var meterTask: Task<Void, Never>?

    private let prompts = [
        "你好，我是这台设备的主人。今天天气不错，我们稍后开会讨论一下接下来的工作安排和待办事项。",
        "平时我会用 Apple Watch 或蓝牙耳机记录日常想法，希望 MoMo 每次都能一眼认出我的声音。"
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: completedSamples > 0 ? "person.crop.circle.badge.checkmark" : "person.wave.2.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(completedSamples > 0 ? MoMoPalette.success : MoMoPalette.ink)
                    .padding(.top, 16)

                VStack(spacing: 8) {
                    Text(completedSamples > 0 ? "声纹已锁定" : "锁定我的声音")
                        .phoneText(.heading)
                    Text("用 10–15 秒自然朗读下面这句话，Mac 端会自动记住你的声纹，以后所有日常录音都能准确标出「我」说的话。")
                        .phoneText(.body)
                        .foregroundStyle(MoMoPalette.muted)
                        .multilineTextAlignment(.center)
                }

                Text("“\(prompts[min(completedSamples, prompts.count - 1)])”")
                    .font(.body)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
                    }

                VStack(spacing: 10) {
                    ProgressView(value: Double(level), total: 1.0)
                        .tint(MoMoPalette.ink)
                    Text(recording ? String(format: "正在录音 %.1f 秒（建议 8–15 秒）", elapsed)
                         : (completedSamples > 0 ? "已录入 \(completedSamples) 条声纹样本" : "点击下方按钮开始朗读"))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(MoMoPalette.muted)
                }

                if let lastQualityText {
                    Label(lastQualityText, systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(MoMoPalette.success)
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(MoMoPalette.failure)
                        .multilineTextAlignment(.center)
                }

                if uploading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在上传到 Mac 提取 ReDimNet2+ 声纹…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if recording {
                    Button {
                        Task { await stopAndEnroll() }
                    } label: {
                        Label("停止并录入声纹", systemImage: "stop.circle.fill")
                    }
                    .buttonStyle(ClientPrimaryButton())
                    .disabled(elapsed < 2.2)
                    .accessibilityIdentifier("voiceprint.onboarding.stop")
                } else {
                    Button {
                        Task { await startRecording() }
                    } label: {
                        Label(completedSamples == 0 ? "开始录制我的声音" : "再补录一条（提升跨设备准确度）", systemImage: "mic.fill")
                    }
                    .buttonStyle(ClientPrimaryButton())
                    .accessibilityIdentifier("voiceprint.onboarding.record")

                    if completedSamples > 0 {
                        Button("完成并开始使用", action: onFinish)
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("voiceprint.onboarding.done")
                    }
                }

                if completedSamples == 0 {
                    Button("稍后再说") {
                        stopRecorderCleanup()
                        (onSkip ?? onFinish)()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MoMoPalette.muted)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("voiceprint.onboarding.skip")
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .phonePageSurface()
        .onDisappear { stopRecorderCleanup() }
    }

    private func startRecording() async {
        error = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            error = "请在系统设置中允许 MoMo Agent 使用麦克风。"
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("momo-owner-enroll-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            guard rec.record() else {
                error = "无法启动录音，请稍后重试。"
                return
            }
            self.recorder = rec
            self.recordingURL = url
            self.elapsed = 0
            self.recording = true
            self.meterTask?.cancel()
            self.meterTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let r = self.recorder, r.isRecording else { return }
                    r.updateMeters()
                    self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 50) / 50))
                    self.elapsed = r.currentTime
                    if r.currentTime >= 30.0 {
                        await self.stopAndEnroll()
                        return
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stopAndEnroll() async {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = recordingURL else { return }
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        guard let client = remoteAgent.speechDataClient else {
            error = "当前未连接到 Mac，请确认 Mac 在线后重试。"
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            error = "未录到有效声音，请重试。"
            return
        }

        uploading = true; error = nil
        defer { uploading = false }
        do {
            let existing = try await client.voiceprintProfiles()
            let owner: VoiceprintProfile
            if let found = existing.first(where: \.isOwner) {
                owner = found
            } else {
                owner = try await client.createVoiceprintProfile(name: "我", isOwner: true)
            }
            let res = try await client.enrollVoiceprintSample(
                profileID: owner.id,
                audioData: data,
                filename: "iphone-onboarding.m4a",
                sourceDevice: "iphone_mic"
            )
            completedSamples = res.profile.sampleCount
            let clean = res.quality.cleanSeconds ?? 0
            let snr = res.quality.snrDb ?? 0
            lastQualityText = String(format: "已提取清晰语音 %.1f 秒（信噪比 %.0f dB）", clean, snr)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stopRecorderCleanup() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        recorder = nil
        recording = false
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}
