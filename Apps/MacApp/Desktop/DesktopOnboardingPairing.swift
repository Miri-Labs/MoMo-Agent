import SwiftUI

/// First pairing keeps network details on a separate page. The runtime owns connectivity.
struct DesktopOnboardingPairing: View {
    @Bindable var model: DesktopModel
    var onFinish: (() -> Void)? = nil
    @State private var customAddress = false

    private var pendingDevices: [AccessStatus.Device] {
        model.status?.devices.filter { $0.state == "pending" } ?? []
    }
    private var pairingActivity: String {
        (model.status?.tunnel.state ?? "") + (model.status?.tunnel.endpoint ?? "")
    }

    var body: some View {
        VStack(spacing: 24) {
            if customAddress || needsNetworkSetup {
                DesktopConnectionSetup(model: model, onSaved: { customAddress = false })
                    .multilineTextAlignment(.leading)
                HStack {
                    if onFinish == nil {
                        Button { model.advanceSetup(.permissions) } label: {
                            Label("返回", systemImage: "chevron.left").padding(.vertical, 6)
                        }.disabled(model.busy != nil).accessibilityIdentifier("pairing.back")
                    }
                    Spacer()
                    Button(onFinish == nil ? "稍后配对" : "取消") { finish() }
                        .padding(.vertical, 6).accessibilityIdentifier("onboarding.finishPairing")
                }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                PersonalAgentSlot(size: 64, active: model.busy != nil, expression: model.pairingAccepted ? .settled : .present)
                if model.pairingAccepted {
                    heading(model.hasPairedPhone ? "配对完成" : "已允许配对", detail: model.hasPairedPhone ? nil : "请在手机完成连接")
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(MoMoPalette.success)
                        .accessibilityIdentifier("desktop.pairingSuccess")
                    Button("继续") { finish() }.buttonStyle(DesktopSetupButton())
                        .accessibilityIdentifier("onboarding.finishPairing")
                } else if !pendingDevices.isEmpty {
                    heading("确认配对")
                    ForEach(pendingDevices) { device in
                        approval(device)
                    }
                } else {
                    heading("扫码配对")
                    invitation
                    Text("用手机上的 MoMo Agent 扫码").font(.system(size: 14)).foregroundStyle(.secondary)
                    HStack(spacing: 24) {
                        Button("配对设置") { customAddress = true }
                            .accessibilityIdentifier("connection.customPairing")
                        Button(onFinish == nil ? "稍后配对" : "取消") { finish() }
                            .accessibilityIdentifier("onboarding.finishPairing")
                    }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if onFinish == nil {
                    Button("返回") { model.advanceSetup(.permissions) }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                        .disabled(model.busy != nil).accessibilityIdentifier("pairing.back")
                }
                if let failure = model.failure {
                    Text(failure).font(.callout).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
                }
            }
        }
        .multilineTextAlignment(.center)
        .task(id: pairingActivity) {
            if onFinish == nil, model.hasPairedPhone { finish(); return }
            await model.beginPairing()
        }
        .onChange(of: model.hasPairedPhone) { _, connected in if connected, onFinish == nil { finish() } }
    }

    private var needsNetworkSetup: Bool {
        ["tailscale", "embedded"].contains(model.status?.tunnel.mode ?? "") && model.status?.tunnel.state != "connected" && pendingDevices.isEmpty
    }

    private func finish() {
        if let onFinish { onFinish() } else { model.advanceSetup(.completed) }
    }

    @ViewBuilder private var invitation: some View {
        if model.status?.tunnel.state == "connected", let invitation = model.status?.invitation {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = max(0, Int(invitation.expires - timeline.date.timeIntervalSince1970))
                VStack(spacing: 20) {
                    if remaining > 0 {
                        PairingQRCode(payload: invitation.payload).frame(width: 184, height: 184)
                            .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 20))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MoMoPalette.line, lineWidth: 1))
                    } else {
                        Image(systemName: "qrcode").font(.system(size: 64)).foregroundStyle(.tertiary)
                            .frame(width: 220, height: 220)
                            .accessibilityLabel("配对码已过期")
                    }
                    HStack(spacing: 10) {
                        Text(remaining > 0 ? "有效期 \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "配对码已过期")
                            .monospacedDigit()
                        Button { Task { await model.control("pair/invite") } } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("刷新二维码").accessibilityLabel("刷新二维码")
                        .accessibilityIdentifier("pairing.refresh").disabled(model.busy != nil)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } else if ["starting", "reconnecting"].contains(model.status?.tunnel.state ?? "") {
            ProgressView(model.status?.tunnel.state == "reconnecting" ? "正在恢复配对…" : "正在准备配对…")
                .controlSize(.small).frame(height: 220)
        } else if model.status?.tunnel.state == "connected" {
            VStack(spacing: 20) {
                ProgressView("正在生成配对码…").controlSize(.small).frame(height: 160)
                Button("重新生成") { Task { await model.control("pair/invite") } }.buttonStyle(.plain)
                    .font(.system(size: 13)).foregroundStyle(.secondary).disabled(model.busy != nil)
            }
        } else {
            if let error = model.status?.tunnel.error {
                Text(error).font(.callout).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
            }
            Button("设置连接") { customAddress = true }
                .buttonStyle(DesktopSetupButton()).disabled(model.busy != nil)
                .accessibilityIdentifier("connection.configure")
        }
    }

    private func approval(_ device: AccessStatus.Device) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Text(device.name).font(.system(size: 14)).foregroundStyle(.secondary)
                Text(device.code).font(.system(size: 36, weight: .medium, design: .monospaced)).tracking(3)
                    .textSelection(.enabled).accessibilityIdentifier("desktop.pairCode")
                Text("确认手机上显示相同数字").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("配对后可接管这台电脑").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(24)
            .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MoMoPalette.line, lineWidth: 1))
            Button("允许配对") {
                Task {
                    if await model.control("pair/decide", body: ["id": device.id, "allow": true]) {
                        model.prepareDesktop()
                    }
                }
            }
                .buttonStyle(DesktopSetupButton()).disabled(model.busy != nil)
                .accessibilityIdentifier("desktop.approvePair")
            Button("拒绝") { Task { await model.control("pair/decide", body: ["id": device.id, "allow": false]) } }
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary).disabled(model.busy != nil)
                .accessibilityIdentifier("desktop.rejectPair")
        }
    }

    private func heading(_ title: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: 28, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(LocalizedStringKey(detail)).font(.system(size: 14)).foregroundStyle(.secondary) }
        }
    }
}
