import SwiftUI

struct PhoneHealthSettingsView: View {
    let health: PhoneHealthSync
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhoneSettingsSurface {
                    HStack {
                        Text("用于 MoMo 对话").phoneText(.body)
                        Spacer(minLength: 16)
                        Toggle("用于 MoMo 对话", isOn: Binding(get: { health.enabled }, set: { enabled in
                        Task { if enabled { await health.enable() } else { await health.disable() } }
                    }))
                    .labelsHidden().tint(MoMoPalette.ink)
                    .disabled(health.isSyncing || (!health.available && !health.enabled) || health.deletionPending)
                    .accessibilityIdentifier("health.enabled")
                    }.padding(.horizontal, 18).frame(minHeight: 58)
                }
                Text("最近 7 天步数和最新心率，同步到你的 Mac。相关问题由所选 AI 服务分析。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if !health.available { Text("此设备不支持健康数据。").phoneText(.metadata).foregroundStyle(MoMoPalette.muted) }
                if health.enabled || health.deletionPending {
                    PhoneSettingsSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            if health.enabled, let date = health.lastSynced {
                                PhoneSettingsValueRow(title: "上次同步", value: Text(date, style: .relative))
                            }
                            Button { Task { await health.refresh() } } label: {
                                HStack { Text(health.deletionPending ? "重试移除 Mac 副本" : "立即同步"); Spacer(); if health.isSyncing { ProgressView().controlSize(.small) } }
                            }.buttonStyle(PhoneActionButtonStyle()).disabled(health.isSyncing)
                        }.padding(18)
                    }
                    if health.enabled && !health.hasReadableData {
                        Text("暂无可读数据。可在「健康」App 检查数据和授权。")
                            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                    }
                }
                Text("打开 App 时同步。关闭后移除 Mac 副本，已有聊天保留。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                if let failure = health.failure {
                    Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure).accessibilityIdentifier("health.error")
                }
            }.padding(24)
        }.phonePageSurface().navigationTitle("健康").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("health.settings")
    }
}
