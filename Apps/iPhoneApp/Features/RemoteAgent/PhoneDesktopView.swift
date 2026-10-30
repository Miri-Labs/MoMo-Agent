import SwiftUI
import MoMoAgentClient
@preconcurrency import WebRTC

struct PhoneDesktopView: View {
    let agent: PhoneRemoteAgent
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    var body: some View {
        NavigationStack {
            Group {
                if let client = agent.desktopClient {
                    RemoteDesktopSessionView(client: client, tailnet: agent.tailnet, pair: { pairing = true })
                        .id(agent.desktopClientID)
                } else {
                    VStack(spacing: 24) {
                        Image(systemName: "desktopcomputer").font(.system(size: 48))
                        Text("配对你的电脑").font(.title2.weight(.semibold))
                        Button("扫码配对") { pairing = true }.buttonStyle(ClientPrimaryButton()).frame(maxWidth: 320)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(MoMoPalette.canvas).navigationTitle("电脑桌面").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭", systemImage: "xmark") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $pairing) { PhoneConnectionFlow(agent: agent, reconnecting: true, finish: { pairing = false }) }
    }
}

private struct RemoteDesktopSessionView: View {
    let pair: () -> Void
    @State private var session: PhoneDesktopSession
    @State private var reconnecting = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboard = false
    init(client: AgentClient, tailnet: EmbeddedTailnet, pair: @escaping () -> Void) {
        self.pair = pair
        _session = State(initialValue: PhoneDesktopSession(client: client, tailnet: tailnet))
    }

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let track = session.videoTrack, session.videoSize.width > 0 {
                    desktopStage(track)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "desktopcomputer").font(.system(size: 46)).foregroundStyle(.secondary)
                        if session.status == nil && session.failure == nil { ProgressView("正在连接电脑…") }
                        else if session.status?.approved == false { Text("请更新电脑上的 MoMo Agent").font(.callout) }
                        else if let status = session.status, !status.screen || !status.input {
                            Text("首次设置远程操控").font(.headline)
                            Text(permissionLabel(status)).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else if session.status?.owner == "other" { Text("另一台设备正在控制电脑").font(.callout) }
                        else if session.failure == nil { ProgressView() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let failure = session.failure {
                Text(failure).font(.footnote).foregroundStyle(MoMoPalette.failure).multilineTextAlignment(.center)
                if session.needsPairing {
                    Button("重新配对", action: pair).buttonStyle(.plain).font(.callout).accessibilityIdentifier("desktop.rePair")
                } else {
                    Button {
                        reconnecting = true
                        Task {
                            defer { reconnecting = false }
                            await session.reconnect()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if reconnecting { ProgressView().controlSize(.small) }
                            Text(reconnecting ? "重连中" : "重连")
                        }
                    }.buttonStyle(.plain).font(.callout).disabled(reconnecting)
                }
            }
            if let status = session.status, status.approved, status.screen, status.input {
                if session.videoTrack == nil { controlIsland(status).frame(maxWidth: .infinity) }
                if status.owner == "you", !status.active {
                    Button("交还 MoMo") { Task { await session.changeControl(returning: true) } }.buttonStyle(.plain).font(.callout)
                }
            } else if session.status != nil, session.failure == nil {
                Button("重新检查") { Task { await session.reconnect() } }.buttonStyle(ClientPrimaryButton()).disabled(session.changingControl)
                    .accessibilityIdentifier("desktop.checkPermissions")
            }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 16)
        .background(alignment: .bottom) {
            PhoneDesktopKeyboard(active: keyboard && session.canControl, sendText: type, sendKey: key, didClose: { keyboard = false })
                .frame(width: 1, height: 1).opacity(0.01)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if session.canControl {
                    Button(keyboard ? "收起键盘" : "键盘", systemImage: keyboard ? "keyboard.chevron.compact.down" : "keyboard") { keyboard.toggle() }
                        .accessibilityIdentifier("desktop.tool.keyboard")
                }
            }
        }
        .task(id: scenePhase == .background) {
            if scenePhase != .background { await session.observe() }
            else { session.suspend() }
        }
        .onChange(of: session.canControl) { _, allowed in if !allowed { keyboard = false } }
        .onDisappear { session.suspend() }
    }

    private func desktopStage(_ track: RTCVideoTrack) -> some View {
        GeometryReader { geometry in
            let hasControls = session.status?.approved == true && session.status?.screen == true && session.status?.input == true
            let availableHeight = max(1, geometry.size.height - (hasControls ? 68 : 0))
            let scale = min(geometry.size.width / max(1, session.videoSize.width), availableHeight / max(1, session.videoSize.height))
            VStack(spacing: 16) {
                PhoneDesktopCanvas(track: track, size: session.videoSize, controlling: session.canControl, send: session.send)
                    .frame(width: session.videoSize.width * scale, height: session.videoSize.height * scale)
                if hasControls, let status = session.status { controlIsland(status) }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder private func controlIsland(_ status: DesktopStatus) -> some View {
        let content = HStack(spacing: 14) {
            Text(controlLabel).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).accessibilityIdentifier("desktop.controlState")
            Button {
                keyboard = false; Task { await session.changeControl() }
            } label: {
                Group {
                    if session.changingControl { ProgressView().controlSize(.small) }
                    else { Text(status.owner == "you" ? (status.active ? "交还" : "重新接管") : "接管") }
                }
                .font(.system(size: 14, weight: .medium)).frame(minWidth: 48, minHeight: 44).padding(.horizontal, 12)
                .foregroundStyle(status.owner == "you" ? MoMoPalette.ink : MoMoPalette.paper)
                .background(status.owner == "you" ? MoMoPalette.paper.opacity(0.5) : MoMoPalette.ink, in: Capsule())
            }
            .buttonStyle(.plain).disabled(session.changingControl || status.owner == "other" || (!session.hasLivePicture && status.owner != "you"))
            .accessibilityIdentifier("desktop.takeControl")
            .accessibilityLabel(status.owner == "you" ? "交还 MoMo" : "接管电脑")
        }.padding(.leading, 18).padding(.trailing, 4).padding(.vertical, 4).fixedSize()
        if #available(iOS 26.0, *) { content.glassEffect(.regular, in: .capsule) }
        else { content.background(.regularMaterial, in: Capsule()).overlay(Capsule().strokeBorder(MoMoPalette.line, lineWidth: 1)) }
    }
    private func key(_ name: String, _ hardwareModifiers: [String]) {
        session.send(.init(kind: "key", key: name, modifiers: hardwareModifiers))
    }
    private func type(_ text: String) {
        var chunk = ""
        func flush() { if !chunk.isEmpty { session.send(.init(kind: "text", text: chunk)); chunk = "" } }
        for character in text {
            if character == "\n" || character == "\r\n" { flush(); key("return", []); continue }
            if chunk.utf16.count + String(character).utf16.count > 1024 { flush() }
            chunk.append(character)
        }
        flush()
    }
    private func permissionLabel(_ status: DesktopStatus) -> String {
        let missing = [status.screen ? nil : String(localized: "屏幕录制"), status.input ? nil : String(localized: "辅助功能")].compactMap { $0 }.joined(separator: String(localized: "与"))
        return String(localized: "在电脑「系统设置 → 隐私与安全性」（或 MoMo Agent「设置 → 设备 → 屏幕与控制权限」）开启") + missing + String(localized: "。以后可直接接管。")
    }
    private var controlLabel: String {
        guard let status = session.status else { return "" }
        if !status.screen || !status.input { return String(localized: "需要首次设置") }
        if status.owner == "you" { return status.active ? String(localized: "你正在控制") : String(localized: "MoMo 已暂停") }
        if status.owner == "other" { return String(localized: "其他设备正在控制") }
        return String(localized: "MoMo 使用中")
    }
}
