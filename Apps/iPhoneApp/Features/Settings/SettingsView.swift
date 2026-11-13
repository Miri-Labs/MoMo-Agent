import SwiftUI
import MoMoArchive
import MoMoContracts
import MoMoAgentClient

struct SettingsView: View {
    let archive: ArchiveStore
    let remoteAgent: PhoneRemoteAgent
    let modelDirectory: URL?
    let modelStatus: LocalSpeechModelStatus
    let speechSettings: PhoneSpeechSettings
    var illustrations: LifeIllustrationStore? = nil
    var earphone: EarphoneCaptureRuntime? = nil
    var speakerRematch: SpeakerRematchController = SpeakerRematchController()
    var onSpeakersChanged: (() async -> Void)? = nil
    @State private var versionTapCount = 0
    @State private var previewingWelcome = false

    var body: some View {
        List {
            Section {
                settingsLink("通用", symbol: "gearshape", id: "settings.general") {
                    generalSettings
                }
                settingsLink("Mac 连接", symbol: "desktopcomputer", value: remoteAgent.connection == nil ? "尚未配对" : "已配对", id: "settings.mac") {
                    PhoneMacConnectionView(agent: remoteAgent, showsDoneButton: false)
                }
                if remoteAgent.connection != nil {
                    settingsLink("通知", symbol: "bell", value: remoteAgent.notifications.title, id: "settings.notifications") {
                        PhoneNotificationSettings(notifications: remoteAgent.notifications)
                    }
                }
            }
            if remoteAgent.health != nil || remoteAgent.sources != nil || remoteAgent.sourcesFailure != nil {
                Section {
                    if let health = remoteAgent.health {
                        settingsLink("健康", symbol: "heart", value: health.enabled ? "已开启" : "未开启", id: "settings.health") {
                            PhoneHealthSettingsView(health: health)
                        }
                    }
                    if let sources = remoteAgent.sources {
                        ForEach(PhoneSourceKind.allCases, id: \.rawValue) { kind in
                            settingsLink(kind.title, symbol: kind.symbol,
                                         value: sources.preference(kind).enabled ? "已开启" : "未开启", id: "settings.\(kind.rawValue)") {
                                PhoneSourcesSettingsView(sources: sources, kind: kind)
                            }
                        }
                    }
                } header: {
                    Text("个人资料")
                } footer: {
                    if let failure = remoteAgent.sourcesFailure {
                        Text(verbatim: failure).foregroundStyle(MoMoPalette.failure)
                    }
                }
            }
            Section("转录") {
                if let earphone {
                    settingsLink("录音设备", symbol: "mic", value: earphone.settings.device.title, id: "settings.captureDevice") {
                        CaptureDeviceSettingsView(runtime: earphone)
                    }
                }
                settingsLink("转录模型", symbol: "waveform", value: speechSettings.models.choice.title, id: "settings.speech.model") {
                    SpeechModelSettingsView(settings: speechSettings.models)
                }
                settingsLink("识别语言", symbol: "globe", value: speechSettings.language.title, id: "settings.speech.language") {
                    SpeechLanguageSettingsView(settings: speechSettings)
                }
                settingsLink("语音检测", symbol: "waveform.badge.magnifyingglass",
                             value: speechSettings.vadThreshold.formatted(.number.precision(.fractionLength(2))), id: "settings.speech.detection") {
                    SpeechDetectionSettingsView(settings: speechSettings)
                }
                settingsLink("说话人分段", symbol: "person.2", value: speechSettings.speakerSegmentationModel.title, id: "settings.speech.segmentation") {
                    SpeakerSegmentationSettingsView(settings: speechSettings)
                }
                settingsLink("人物与声纹", symbol: "person.wave.2", id: "settings.speakers") {
                    SpeakerProfilesView(archive: archive, rematch: speakerRematch, onSpeakersChanged: onSpeakersChanged)
                }
            }
            Section {
                settingsLink("储存空间", symbol: "internaldrive", id: "settings.storage") {
                    StorageUsageView(archive: archive, modelDirectory: modelDirectory, modelStatus: modelStatus)
                }
            } footer: {
                Button {
                    versionTapCount += 1
                    if versionTapCount == 7 { versionTapCount = 0; previewingWelcome = true }
                } label: {
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.version")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .task { await illustrations?.refresh(minimumInterval: 3) }
        .onDisappear { versionTapCount = 0 }
        .fullScreenCover(isPresented: $previewingWelcome) {
            WelcomeExperienceView(finishTitle: "返回设置", finish: { previewingWelcome = false }, closePreview: { previewingWelcome = false })
        }
    }

    private var generalSettings: some View {
        Form {
            if let store = remoteAgent.store {
                Section("对话模式") { ChatModeSettings(store: store) }
            }
            Section {
                settingsLink("每天起点", symbol: "clock", value: speechSettings.dayStartHourLabel, id: "settings.advanced.dayStartHour") {
                    DayStartSettingsView(settings: speechSettings)
                }
                if let illustrations {
                    settingsLink("生活插画", symbol: "photo", value: illustrations.settingsRowStatus, id: "settings.lifeIllustrations") {
                        LifeIllustrationSettingsView(store: illustrations)
                    }
                }
            }
        }
        .navigationTitle("通用")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func settingsLink<Destination: View>(
        _ title: String, symbol: String, value: String? = nil, id: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(destination: destination()) {
            LabeledContent {
                if let value { Text(LocalizedStringKey(value)).multilineTextAlignment(.trailing) }
            } label: {
                Label {
                    Text(LocalizedStringKey(title))
                } icon: {
                    Image(systemName: symbol).symbolVariant(.none).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(id)
    }
}

extension AudioRetentionPolicy {
    var title: String {
        switch self {
        case .days(let days): String(localized: "\(days) 天")
        case .forever: String(localized: "永久")
        }
    }
}

private struct PhoneNotificationSettings: View {
    let notifications: PhoneNotifications
    var body: some View {
        Form {
            Section {
                LabeledContent("通知状态") { Text(LocalizedStringKey(notifications.title)) }
                if notifications.status?.configured == true {
                    Toggle("接收通知", isOn: Binding(
                        get: { notifications.status?.enabled == true && notifications.allowed },
                        set: { enabled in Task { if enabled { await notifications.enable() } else { await notifications.disable() } } }
                    ))
                    .disabled(notifications.busy)
                    .accessibilityIdentifier("settings.notifications.enabled")
                }
                if notifications.busy { ProgressView().controlSize(.small) }
            } footer: {
                if notifications.status?.configured == false { Text("Mac 尚未配置推送服务") }
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refresh() }
    }
}

private struct DayStartSettingsView: View {
    let settings: PhoneSpeechSettings

    var body: some View {
        Form {
            Section {
                Picker("每天起点", selection: Binding(
                    get: { settings.dayStartHour }, set: { settings.selectDayStartHour($0) }
                )) {
                    ForEach(Array(PhoneSpeechSettings.dayStartHourRange), id: \.self) { hour in
                        Text(DayStartBoundary.label(for: hour)).monospacedDigit().tag(hour)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.advanced.dayStartHour.picker")
                Button("恢复默认") { settings.selectDayStartHour(PhoneSpeechSettings.defaultDayStartHour) }
                    .disabled(settings.dayStartHour == PhoneSpeechSettings.defaultDayStartHour)
                    .accessibilityIdentifier("settings.advanced.dayStartHour.reset")
            } footer: {
                Text("早于该时间的凌晨录音会归入前一天。默认 08:00。")
                Text("修改后立即重排时间线日期归属，已有录音和文字保留。")
            }
            if let failure = settings.failure { Text(verbatim: failure).foregroundStyle(MoMoPalette.failure) }
        }
        .navigationTitle("每天起点")
        .navigationBarTitleDisplayMode(.inline)
    }
}
