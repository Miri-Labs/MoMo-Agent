import SwiftUI
import MoMoArchive
import MoMoContracts
import MoMoAgentClient

struct SettingsView: View {
    let archive: ArchiveStore
    let remoteAgent: PhoneRemoteAgent
    var uploader: AudioUploadCoordinator? = nil
    let speechSettings: PhoneSpeechSettings
    var illustrations: LifeIllustrationStore? = nil
    var earphone: EarphoneCaptureRuntime? = nil
    var onSpeakersChanged: (() async -> Void)? = nil
    @State private var versionTapCount = 0
    @State private var previewingWelcome = false

    private var macSpeechRowValue: String {
        if remoteAgent.speechDataClient == nil { return String(localized: "未连接") }
        if uploader?.macStatus?.settings.paused == true { return String(localized: "已暂停") }
        return "Mac Core ML"
    }

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
            if remoteAgent.deviceTelemetry != nil || remoteAgent.health != nil || remoteAgent.sources != nil || remoteAgent.sourcesFailure != nil {
                Section {
                    if let telemetry = remoteAgent.deviceTelemetry {
                        settingsLink("设备状态（电量与连接）", symbol: "battery.100percent", value: telemetry.enabled ? "已开启" : "未开启", id: "settings.deviceTelemetry") {
                            PhoneDeviceTelemetrySettingsView(telemetry: telemetry)
                        }
                    }
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
            Section("录音与声纹") {
                if let earphone {
                    settingsLink("录音设备", symbol: "mic", value: earphone.settings.device.title, id: "settings.captureDevice") {
                        CaptureDeviceSettingsView(runtime: earphone)
                    }
                }
                settingsLink("Mac 转录设置", symbol: "waveform", value: macSpeechRowValue, id: "settings.speech.mac") {
                    MacSpeechSettingsView(remoteAgent: remoteAgent, uploader: uploader)
                }
                settingsLink("人物与声纹", symbol: "person.wave.2", id: "settings.speakers") {
                    SpeakerProfilesView(
                        archive: archive,
                        remoteAgent: remoteAgent,
                        uploader: uploader,
                        onSpeakersChanged: onSpeakersChanged
                    )
                }
            }
            Section {
                settingsLink("储存空间", symbol: "internaldrive", id: "settings.storage") {
                    StorageUsageView(archive: archive)
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
                settingsLink("凌晨记录默认折叠至", symbol: "clock", value: speechSettings.dayStartHourLabel, id: "settings.advanced.dayStartHour") {
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
                Picker("凌晨记录默认折叠至", selection: Binding(
                    get: { settings.dayStartHour }, set: { settings.selectDayStartHour($0) }
                )) {
                    ForEach(Array(PhoneSpeechSettings.dayStartHourRange), id: \.self) { hour in
                        Text(TranscriptReadingBoundary.label(for: hour)).monospacedDigit().tag(hour)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.advanced.dayStartHour.picker")
                Button("恢复默认") { settings.selectDayStartHour(PhoneSpeechSettings.defaultDayStartHour) }
                    .disabled(settings.dayStartHour == PhoneSpeechSettings.defaultDayStartHour)
                    .accessibilityIdentifier("settings.advanced.dayStartHour.reset")
            } footer: {
                Text("只折叠显示，不改变录音日期。默认 08:00。")
                Text("选择“全部展开”可按时间顺序阅读全天。")
            }
            if let failure = settings.failure { Text(verbatim: failure).foregroundStyle(MoMoPalette.failure) }
        }
        .navigationTitle("凌晨记录默认折叠至")
        .navigationBarTitleDisplayMode(.inline)
    }
}
