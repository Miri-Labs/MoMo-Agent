import AppKit
import SwiftUI

/// Shared by first connection and subsequent device management.
struct DesktopConnectionSetup: View {
    @Bindable var model: DesktopModel
    var inSettings = false
    var onSaved: () -> Void = {}
    @State private var customAddress = false
    @State private var showingHelp = false
    @State private var showingTailnetHelp = false
    @State private var checkingConnection = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var login = TailnetLogin()
    private var loginLoading: Bool { model.busy != nil || login.busy }
    private var externalChecking: Bool {
        model.busy != nil || (checkingConnection && model.status?.tunnel.mode == "external" &&
            ["starting", "reconnecting"].contains(model.status?.tunnel.state ?? "") && model.status?.tunnel.error == nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if inSettings {
                settings
            } else if !customAddress {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image("TailscaleBrand").resizable().scaledToFit().frame(width: 143, height: 26)
                            .accessibilityLabel("Tailscale").accessibilityAddTraits(.isHeader)
                        Spacer()
                        Menu {
                            Button("连接帮助") { showingTailnetHelp = true }
                            Button("自建服务器") { customAddress = true }
                                .accessibilityIdentifier("connection.stableGuide")
                            if model.tailnet.state == "Running" {
                                Button("退出账号") { Task { await model.logoutTailnet() } }.disabled(model.busy != nil)
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("更多连接选项")
                            .popover(isPresented: $showingTailnetHelp) { TailnetHelp() }
                    }
                    Rectangle().fill(MoMoPalette.line).frame(height: 1).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("连接你的设备")
                            .font(.system(size: 20, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Text("手机与 Mac 登录同一 Tailscale 账号")
                            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.tailnet.state != "Running" {
                        Button {
                            connectTailnet()
                        } label: {
                            if loginLoading { Text("正在连接") }
                            else {
                                Label("登录 Tailscale", systemImage: "arrow.up.right")
                                    .labelStyle(.titleAndIcon)
                            }
                        }.buttonStyle(DesktopSetupButton(minimumHeight: 44, fontSize: 14, isLoading: loginLoading))
                            .disabled(loginLoading).accessibilityIdentifier("connection.checkTailscale")
                        if let error = login.error, !loginLoading { Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure) }
                    } else if model.status?.tunnel.state == "connected" {
                        Button("继续", action: onSaved)
                            .buttonStyle(DesktopSetupButton(minimumHeight: 44, fontSize: 14))
                    } else if let error = model.tailnetAccessError {
                        Text(error).font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("重试") { Task { await model.refresh() } }
                            .buttonStyle(DesktopSetupButton(minimumHeight: 44, fontSize: 14))
                    } else {
                        Button("正在连接") { }
                            .buttonStyle(DesktopSetupButton(minimumHeight: 44, fontSize: 14, isLoading: true))
                            .disabled(true)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MoMoPalette.line, lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text("连接自建服务器").font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    Text("服务器负责转发，MoMo 仍在这台 Mac 上运行。").font(.system(size: 14)).foregroundStyle(.secondary)
                    Text("HTTPS 地址").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("https://example.com", text: $model.endpoint)
                        .textFieldStyle(.plain).font(.system(size: 14)).padding(.horizontal, 14).frame(height: 44)
                        .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MoMoPalette.line, lineWidth: 1))
                        .accessibilityLabel("HTTPS 地址")
                        .accessibilityIdentifier("connection.stableEndpoint")
                        .disabled(externalChecking)
                    Button(externalChecking ? "正在检查" : "保存并检查") {
                        connectExternal()
                    }.buttonStyle(DesktopSetupButton(minimumHeight: 44, fontSize: 14, isLoading: externalChecking))
                        .disabled(model.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || externalChecking)
                        .accessibilityIdentifier("connection.useStable")
                    Button("设置帮助") { showingHelp = true }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                        .popover(isPresented: $showingHelp) {
                        serverHelp
                    }
                    Button("返回连接方式") { customAddress = false }
                        .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let error = model.failure, !loginLoading {
                Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
            } else if let error = model.status?.tunnel.error, customAddress, model.status?.tunnel.mode == "external", !externalChecking {
                Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
            }
            if customAddress { Text("更换地址后需要重新配对").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .onChange(of: model.status?.tunnel.state) { _, state in
            if checkingConnection, state == "connected" { checkingConnection = false; onSaved() }
        }
        .onChange(of: customAddress) { _, _ in
            connectionTask?.cancel(); login.cancel(); checkingConnection = false; model.failure = nil
        }
        .onDisappear { connectionTask?.cancel(); login.cancel() }
        .onAppear {
            if model.status?.tunnel.mode == "external" {
                customAddress = true
                if model.endpoint.isEmpty { model.endpoint = model.status?.tunnel.endpoint ?? "" }
            }
        }
    }

    @ViewBuilder private var settings: some View {
        if customAddress {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自建服务器").font(.system(size: 14, weight: .medium))
                    Text("服务器负责转发，MoMo 仍在这台 Mac 上运行。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Text("HTTPS 地址").font(.system(size: 14, weight: .medium)).fixedSize()
                    Spacer(minLength: 0)
                    TextField("https://example.com", text: $model.endpoint)
                        .textFieldStyle(.plain).font(.system(size: 14)).padding(.horizontal, 12).frame(height: 40)
                        .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: 280).disabled(externalChecking)
                        .accessibilityLabel("HTTPS 地址").accessibilityIdentifier("connection.stableEndpoint")
                }.desktopSettingsRow()
                HStack {
                    Button("返回 Tailscale") { customAddress = false }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button(externalChecking ? "正在检查" : "保存并检查", action: connectExternal)
                        .buttonStyle(DesktopSetupButton(minimumHeight: 36, fontSize: 13, isLoading: externalChecking)).frame(width: 112)
                        .disabled(model.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || externalChecking)
                        .accessibilityIdentifier("connection.useStable")
                }.font(.system(size: 13))
                Button("设置帮助") { showingHelp = true }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                    .popover(isPresented: $showingHelp) { serverHelp }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tailscale 私网").font(.system(size: 14, weight: .medium))
                        if model.tailnet.state != "Running" {
                            Text("手机与 Mac 登录同一账号").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 16)
                    if model.tailnet.state != "Running" {
                        Button("登录", action: connectTailnet)
                            .buttonStyle(DesktopSetupButton(minimumHeight: 36, fontSize: 13, isLoading: loginLoading)).frame(width: 112)
                            .disabled(loginLoading).accessibilityIdentifier("connection.checkTailscale")
                    } else {
                        Text(model.status?.tunnel.state == "connected" ? "已连接" : ["starting", "reconnecting"].contains(model.status?.tunnel.state ?? "") ? "正在连接" : "未连接")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        Menu {
                            Button("退出账号") { Task { await model.logoutTailnet() } }.disabled(model.busy != nil)
                        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle()) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Tailscale 账号")
                    }
                }.desktopSettingsRow()
                if let error = login.error ?? model.tailnetAccessError, !loginLoading {
                    HStack {
                        Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure)
                        Spacer()
                        Button("重试") { Task { await model.refresh() } }.buttonStyle(.plain).font(.system(size: 13))
                    }.desktopSettingsRow()
                }
                Button { customAddress = true } label: {
                    HStack {
                        Text("自建服务器").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                    }.desktopSettingsRow().contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(loginLoading).accessibilityIdentifier("connection.stableGuide")
                Button { showingTailnetHelp = true } label: {
                    HStack {
                        Text("连接帮助").font(.system(size: 14, weight: .medium))
                        Spacer()
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                    }.desktopSettingsRow().contentShape(Rectangle())
                }.buttonStyle(.plain).popover(isPresented: $showingTailnetHelp) { TailnetHelp() }
            }
        }
    }

    private var serverHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. 在自己的服务器部署固定域名与 HTTPS。")
            Text("2. 在 Mac 运行 frp 等连接器，将入口转发到：")
            Text(model.localAccessURL).textSelection(.enabled)
                .accessibilityIdentifier("connection.localTarget")
            Text("3. 保持连接器运行，填入 HTTPS 地址，检查通过后扫码。App 不会代为部署服务器。")
            Text("转发需支持 SSE，关闭响应缓冲；保留鉴权与事件游标请求头，无需额外网页登录。")
            Link("frp 配置指南", destination: URL(string: "https://gofrp.org/zh-cn/docs/")!)
        }.font(.system(size: 13)).foregroundStyle(.secondary).padding(24).frame(width: 340)
    }

    private func connectTailnet() {
        connectionTask = Task {
            checkingConnection = true
            if model.status?.tunnel.mode != "embedded",
               !(await model.control("tunnel/configure", body: ["provider": "embedded"])) {
                checkingConnection = false; return
            }
            guard !Task.isCancelled else { return }
            if model.status?.tunnel.state == "stopped" {
                guard await model.control("tunnel/start") else { checkingConnection = false; return }
            }
            guard !Task.isCancelled else { return }
            login.begin(model.tailnet)
        }
    }

    private func connectExternal() {
        connectionTask = Task {
            checkingConnection = true
            guard await model.control("tunnel/configure", body: ["provider": "external", "endpoint": model.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)]) else {
                checkingConnection = false; return
            }
            guard !Task.isCancelled else { return }
            if !(await model.control("tunnel/start")) { checkingConnection = false }
        }
    }

}
