import SwiftUI

struct CaptureDeviceSettingsView: View {
    let runtime: EarphoneCaptureRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("同一时间只用一个设备录音。")
                    .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                VStack(spacing: 0) {
                    ForEach(CaptureDevice.allCases) { device in
                        if device != CaptureDevice.allCases.first { Divider().padding(.leading, 18) }
                        Button {
                            Task { await runtime.select(device) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: device.symbol).frame(width: 22).accessibilityHidden(true)
                                Text(device.title).phoneText(.body)
                                Spacer(minLength: 12)
                                if runtime.settings.device == device {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(MoMoPalette.ink)
                            .padding(.horizontal, 18).frame(minHeight: 58)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(runtime.settings.device == device ? .isSelected : [])
                        .accessibilityIdentifier("settings.captureDevice.\(device.rawValue)")
                    }
                }
                .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                if runtime.settings.device == .earphone { earphoneDetails }
            }
            .padding(24)
        }
        .phonePageSurface()
        .navigationTitle("录音设备")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var earphoneDetails: some View {
        PhoneSettingsSurface {
            PhoneSettingsValueRow(title: String(localized: "当前耳机"),
                                  value: Text(runtime.headsetName ?? String(localized: "未连接")))
                .padding(.horizontal, 18)
            Divider().padding(.leading, 18)
            PhoneSettingsValueRow(title: String(localized: "状态"), value: Text(EarphoneStatusPresentation(runtime).title))
                .padding(.horizontal, 18)
        }
        Text("MoMo Agent 不能自行连接耳机。请先在系统设置的蓝牙中连接；打开 App 时自动开始录音。")
            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
        Text("只保存耳机麦克风的声音。其他 App 播放声音时，耳机保持高音质并暂停保存，声音停止 1 秒后自动继续录音；录音期间耳机按键无法恢复播放。")
            .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
    }
}
