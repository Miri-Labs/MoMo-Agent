import SwiftUI
import MoMoAgentClient

extension PhoneSourceKind {
    var title: String {
        switch self {
        case .visits: String(localized: "到访地点")
        case .calendar: String(localized: "日历")
        case .reminders: String(localized: "提醒事项")
        case .motion: String(localized: "运动与出行状态")
        }
    }
    var symbol: String {
        switch self {
        case .visits: "location"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .motion: "figure.walk"
        }
    }
    var scope: String {
        switch self {
        case .visits: String(localized: "最近 7 天的停留与移动轨迹。")
        case .calendar: String(localized: "过去 24 小时和未来 7 天的日程，只读不修改。")
        case .reminders: String(localized: "未完成的提醒事项，包含逾期和未设日期的事项，只读不修改。")
        case .motion: String(localized: "最近 24 小时步行、跑步、骑行或乘车等出行状态，只读不修改。")
        }
    }
}

struct PhoneSourcesSettingsView: View {
    let sources: PhoneSourcesSync
    let kind: PhoneSourceKind
    @Environment(\.openURL) private var openURL
    private var preference: PhoneSourcesSync.Preference { sources.preference(kind) }
    private var busy: Bool { sources.busy.contains(kind) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhoneSettingsSurface {
                    HStack {
                        Text("用于 MoMo 对话").phoneText(.body)
                        Spacer(minLength: 16)
                        Toggle("用于 MoMo 对话", isOn: Binding(get: { preference.enabled }, set: { value in
                        Task { if value { await sources.enable(kind) } else { await sources.disable(kind) } }
                    }))
                    .labelsHidden().tint(MoMoPalette.ink).disabled(busy)
                    .accessibilityIdentifier("source.\(kind.rawValue).enabled")
                    }.padding(.horizontal, 18).frame(minHeight: 58)
                }
                Text(kind.scope + String(localized: "同步到你的 Mac，相关问题由所选 AI 服务分析。"))
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if kind == .motion && sources.authorization(.motion) == "unavailable" {
                    Text("此设备不支持运动与出行状态检测。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                if preference.enabled {
                    PhoneSettingsSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            if let date = preference.lastSynced { PhoneSettingsValueRow(title: "上次同步", value: Text(date, style: .relative)) }
                            if sources.canPromptAuthorization(kind) {
                                Button(kind == .visits ? "请求定位权限" : "请求系统权限") {
                                    Task { await sources.requestPermission(kind) }
                                }.disabled(busy)
                            } else if sources.authorization(kind) == "needs_permission" {
                                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                            }
                            if kind == .visits && sources.authorization(kind) == "foreground_only" {
                                Button("允许后台记录到访") { sources.requestBackgroundVisits() }
                            }
                            Button { Task { await sources.refresh(kind) } } label: {
                                HStack { Text("立即同步"); Spacer(); if busy { ProgressView().controlSize(.small) } }
                            }.disabled(busy)
                        }.phoneText(.body).buttonStyle(PhoneActionButtonStyle()).padding(18)
                    }
                    Text("打开 App 时同步。关闭后移除 Mac 副本，已有聊天保留。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                } else if preference.pending != nil {
                    Button { Task { await sources.refresh(kind) } } label: {
                        HStack { Text("重试移除 Mac 副本"); Spacer(); if busy { ProgressView().controlSize(.small) } }
                    }.buttonStyle(PhoneActionButtonStyle()).disabled(busy)
                }
                if let failure = sources.failures[kind] { Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure) }
            }.padding(24)
        }.phonePageSurface()
        .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("source.\(kind.rawValue).settings")
    }
}

struct PhoneDeviceTelemetrySettingsView: View {
    let telemetry: PhoneDeviceTelemetrySync

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhoneSettingsSurface {
                    HStack {
                        Text("用于 MoMo 对话").phoneText(.body)
                        Spacer(minLength: 16)
                        Toggle("用于 MoMo 对话", isOn: Binding(
                            get: { telemetry.enabled },
                            set: { value in
                                Task {
                                    if value { await telemetry.enable() }
                                    else { await telemetry.disable() }
                                }
                            }
                        ))
                        .labelsHidden().tint(MoMoPalette.ink)
                        .disabled(telemetry.isSyncing || telemetry.deletionPending)
                        .accessibilityIdentifier("deviceTelemetry.enabled")
                    }.padding(.horizontal, 18).frame(minHeight: 58)
                }
                Text("同步 iPhone 与配对 Apple Watch 的电量、充电状态、低电量模式、温度状态、剩余空间与音频连接方式，无需额外系统权限。同步到你的 Mac，帮助 MoMo 感知设备状态与适时提醒充电。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if telemetry.enabled || telemetry.deletionPending {
                    PhoneSettingsSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            if telemetry.enabled, let date = telemetry.lastSynced {
                                PhoneSettingsValueRow(title: "上次同步", value: Text(date, style: .relative))
                            }
                            Button { Task { await telemetry.refresh() } } label: {
                                HStack {
                                    Text(telemetry.deletionPending ? "重试移除 Mac 副本" : "立即同步")
                                    Spacer()
                                    if telemetry.isSyncing { ProgressView().controlSize(.small) }
                                }
                            }.buttonStyle(PhoneActionButtonStyle()).disabled(telemetry.isSyncing)
                        }.padding(18)
                    }
                }
                Text("默认开启，打开 App 或后台同步录音时更新。关闭后移除 Mac 副本，已有聊天保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if let failure = telemetry.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure)
                        .accessibilityIdentifier("deviceTelemetry.error")
                }
            }.padding(24)
        }
        .phonePageSurface()
        .navigationTitle("设备状态（电量与连接）")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("deviceTelemetry.settings")
    }
}
