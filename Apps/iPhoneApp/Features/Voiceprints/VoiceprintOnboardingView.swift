import AVFoundation
import SwiftUI
import MoMoAgentClient

/// Minimal AI-native voice onboarding: one sentence, one pulsing mic orb, zero clutter.
struct VoiceprintOnboardingView: View {
    let remoteAgent: PhoneRemoteAgent
    var targetProfile: VoiceprintProfile? = nil
    let onFinish: () -> Void
    var onSkip: (() -> Void)? = nil

    @State private var recording = false
    @State private var elapsed: Double = 0
    @State private var level: Float = 0
    @State private var uploading = false
    @State private var completedSamples = 0
    @State private var ownerName = ""
    @State private var error: String?
    @State private var recorder: AVAudioRecorder?
    @State private var recordingURL: URL?
    @State private var meterTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    private var isForOtherPerson: Bool {
        if let targetProfile, !targetProfile.isOwner { return true }
        return false
    }

    private var trimmedOwnerName: String {
        ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var headingText: String {
        if completedSamples > 0 {
            if let targetProfile, !targetProfile.isOwner {
                return "已记住「\(targetProfile.name)」的声音"
            }
            return trimmedOwnerName.isEmpty ? "已记住你的声音" : "已记住「\(trimmedOwnerName)」的声音"
        }
        if let targetProfile, !targetProfile.isOwner {
            return "让「\(targetProfile.name)」读出这句话"
        }
        return "读出这句话"
    }

    private var currentPrompt: String {
        if let targetProfile, !targetProfile.isOwner {
            return "你好，我是\(targetProfile.name)，今天我们来聊聊接下来的安排。"
        }
        if completedSamples == 0, !trimmedOwnerName.isEmpty {
            return "你好，我是\(trimmedOwnerName)，今天来聊聊接下来的安排。"
        }
        return prompts[min(completedSamples, prompts.count - 1)]
    }

    private let prompts = [
        "你好，我是这台设备的主人，今天来聊聊接下来的安排。",
        "平时我会用手表和耳机随手记下想法，希望你一眼认出我的声音。"
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Text(headingText)
                    .phoneText(.heading)

                if !isForOtherPerson {
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle")
                            .foregroundStyle(MoMoPalette.muted)
                            .accessibilityHidden(true)
                        TextField("你的名字（可选，留空显示「我」）", text: $ownerName)
                            .textContentType(.name)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .disabled(recording || uploading)
                            .accessibilityIdentifier("voiceprint.onboarding.name")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
                    }
                }

                Text("“\(currentPrompt)”")
                    .font(.title3.weight(.regular))
                    .lineSpacing(5)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
                    }

                // Pulsing live voice orb
                VStack(spacing: 14) {
                    Button {
                        if recording {
                            Task { await stopAndEnroll() }
                        } else {
                            Task { await startRecording() }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill((recording ? MoMoPalette.failure : (completedSamples > 0 ? MoMoPalette.success : MoMoPalette.ink)).opacity(recording ? 0.14 : 0.06))
                                .frame(width: 92 + CGFloat(level) * 44, height: 92 + CGFloat(level) * 44)
                                .animation(.easeOut(duration: 0.1), value: level)
                            Circle()
                                .fill(recording ? MoMoPalette.failure : (completedSamples > 0 ? MoMoPalette.success : MoMoPalette.ink))
                                .frame(width: 76, height: 76)
                            if uploading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: recording ? "stop.fill" : (completedSamples > 0 ? "checkmark" : "mic.fill"))
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 140, height: 140)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(uploading || (recording && elapsed < 2.2))
                    .accessibilityLabel(recording ? "停止录音" : "开始录音")
                    .accessibilityIdentifier(recording ? "voiceprint.onboarding.stop" : "voiceprint.onboarding.record")

                    if recording {
                        Text(String(format: "%.1fs", elapsed))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(MoMoPalette.muted)
                    } else if uploading {
                        Text("学习声纹中…")
                            .font(.footnote)
                            .foregroundStyle(MoMoPalette.muted)
                    } else if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(MoMoPalette.failure)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(" ")
                            .font(.footnote)
                    }
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 440)

            Spacer()

            VStack(spacing: 8) {
                if completedSamples > 0 {
                    Button("完成", action: onFinish)
                        .buttonStyle(ClientPrimaryButton())
                        .accessibilityIdentifier("voiceprint.onboarding.done")
                } else if let onSkip {
                    Button("跳过") {
                        stopRecorderCleanup()
                        onSkip()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MoMoPalette.muted)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("voiceprint.onboarding.skip")
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .phonePageSurface()
        .task {
            guard !isForOtherPerson else { return }
            if let explicit = targetProfile, explicit.isOwner, explicit.name != "我" {
                ownerName = explicit.name
                return
            }
            if let client = remoteAgent.speechDataClient,
               let existingOwner = (try? await client.voiceprintProfiles())?.first(where: \.isOwner),
               existingOwner.name != "我" {
                ownerName = existingOwner.name
            }
        }
        .onDisappear { stopRecorderCleanup() }
    }

    private func startRecording() async {
        nameFocused = false
        error = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            error = "请在系统设置中允许麦克风权限。"
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
                error = "无法启动录音，请重试。"
                return
            }
            self.recorder = rec
            self.recordingURL = url
            self.elapsed = 0
            self.recording = true
            self.meterTask?.cancel()
            self.meterTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
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
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = recordingURL else { return }
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        guard let client = remoteAgent.speechDataClient else {
            error = "未连接到 Mac。"
            return
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            error = "未录到声音，请重试。"
            return
        }

        uploading = true; error = nil
        defer { uploading = false }
        do {
            let desiredOwnerName = trimmedOwnerName.isEmpty ? nil : String(trimmedOwnerName.prefix(80))
            let target: VoiceprintProfile
            if let explicit = targetProfile {
                if explicit.isOwner, let desiredOwnerName, desiredOwnerName != explicit.name {
                    target = try await client.updateVoiceprintProfile(
                        id: explicit.id,
                        name: desiredOwnerName,
                        isOwner: true,
                        aliases: explicit.aliases,
                        memoryFile: explicit.memoryFile,
                        notes: explicit.notes
                    )
                } else {
                    target = explicit
                }
            } else {
                let existing = try await client.voiceprintProfiles()
                if let found = existing.first(where: \.isOwner) {
                    if let desiredOwnerName, desiredOwnerName != found.name {
                        target = try await client.updateVoiceprintProfile(
                            id: found.id,
                            name: desiredOwnerName,
                            isOwner: true,
                            aliases: found.aliases,
                            memoryFile: found.memoryFile,
                            notes: found.notes
                        )
                    } else {
                        target = found
                    }
                } else {
                    target = try await client.createVoiceprintProfile(
                        name: desiredOwnerName ?? "我",
                        isOwner: true
                    )
                }
            }
            let res = try await client.enrollVoiceprintSample(
                profileID: target.id,
                audioData: data,
                filename: "iphone-mic.m4a",
                sourceDevice: "iphone_mic"
            )
            completedSamples = res.profile.sampleCount
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
        level = 0
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }
}
