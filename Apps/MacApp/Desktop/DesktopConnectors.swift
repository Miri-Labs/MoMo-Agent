import AppKit
import SwiftUI

private struct ConnectorsStatusResponse: Decodable {
    struct FeishuStatus: Decodable {
        let enabled: Bool
        let connected: Bool
        let domain: String
        let app_id: String
        let has_secret: Bool
        let account_label: String
        let last_synced: Double?
        let last_error: String?
        let item_count: Int
    }

    struct EmailStatus: Decodable {
        let enabled: Bool
        let connected: Bool
        let provider: String
        let pending: Bool
        let has_api_key: Bool
        let needs_reconnect: Bool
        let account_label: String
        let last_synced: Double?
        let last_error: String?
        let item_count: Int
    }

    struct ConnectorsBlock: Decodable {
        let feishu: FeishuStatus
        let email: EmailStatus
    }

    let connectors: ConnectorsBlock
}

struct DesktopConnectorsView: View {
    let model: DesktopModel
    @Environment(\.dismiss) private var dismiss

    @State private var status: ConnectorsStatusResponse?
    @State private var busyConnector: String?
    @State private var errorMessage: String?

    @State private var expandFeishuManual = false
    @State private var feishuDomain = "feishu"
    @State private var feishuAppID = ""
    @State private var feishuAppSecret = ""
    @State private var awaitingFeishuOAuth = false
    @State private var feishuRedirectURI = ""

    var body: some View {
        Form {
            Section {
                feishuRow
                if expandFeishuManual {
                    feishuManualFields
                }
                if awaitingFeishuOAuth, !feishuRedirectURI.isEmpty {
                    feishuCallbackRow
                }
            }

            Section {
                ComposioMailSetup(model: model, status: status?.connectors.email) {
                    await refreshStatus(hydrateFields: false)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(MoMoPalette.failure)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshStatus(hydrateFields: true) }
    }

    // MARK: - Feishu

    private var feishuRow: some View {
        let fs = status?.connectors.feishu
        let connected = fs?.connected == true
        return HStack(spacing: 12) {
            FeishuConnectorIcon(connected: connected)

            VStack(alignment: .leading, spacing: 2) {
                Text("飞书")
                    .font(.system(size: 14, weight: .medium))
                if connected, let fs {
                    Text(connectedMeta(label: fs.account_label.isEmpty ? fs.app_id : fs.account_label, count: fs.item_count, synced: fs.last_synced))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let err = fs?.last_error, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(MoMoPalette.failure)
                        .lineLimit(1)
                }
            }

            Spacer()

            if connected {
                Button("同步") { Task { await syncNow("feishu") } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busyConnector != nil)

                Menu {
                    Button("让 MoMo 排查") { askMoMoToConfigureFeishu(reconnect: true) }
                    Button("重新授权") { expandFeishuManual.toggle() }
                    Divider()
                    Button("断开连接", role: .destructive) { Task { await disconnect("feishu") } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("让 MoMo 帮我配") {
                    askMoMoToConfigureFeishu(reconnect: false)
                }
                .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
                .disabled(busyConnector != nil)

                Button(expandFeishuManual ? "收起" : "手动") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandFeishuManual.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busyConnector != nil)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var feishuManualFields: some View {
        let fs = status?.connectors.feishu
        Picker("区域", selection: $feishuDomain) {
            Text("飞书").tag("feishu")
            Text("Lark").tag("lark")
        }
        .pickerStyle(.segmented)

        TextField("App ID", text: $feishuAppID, prompt: Text(verbatim: "cli_xxxxxxxx"))
            .textFieldStyle(.roundedBorder)

        SecureField("App Secret", text: $feishuAppSecret, prompt: Text(fs?.has_secret == true ? "已保存" : "App Secret"))
            .textFieldStyle(.roundedBorder)

        HStack {
            Spacer()
            Button("授权登录") {
                Task { await startFeishuOAuth() }
            }
            .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
            .disabled(busyConnector != nil || feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var feishuCallbackRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(feishuRedirectURI)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(feishuRedirectURI, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    // MARK: - AI-Native Handoff

    private func askMoMoToConfigureFeishu(reconnect: Bool) {
        errorMessage = nil
        guard let store = model.taskStore else {
            errorMessage = "MoMo 尚未在线，请稍候再试。"
            return
        }
        let prompt = reconnect
            ? "帮我检查一下飞书连接器的状态和同步情况，有问题的话按 connectors-setup skill 顺手帮我修好。"
            : "帮我接入飞书连接器，只读同步我的飞书群聊消息和云文档。"
        do {
            try store.enqueueIndependentMessage(prompt)
            dismiss()
            if let mainWindow = NSApp.windows.first(where: { $0.canBecomeMain && !$0.title.localizedCaseInsensitiveContains("setting") && !$0.title.contains("设置") }) {
                mainWindow.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - API Actions

    private func refreshStatus(hydrateFields: Bool) async {
        errorMessage = nil
        do {
            let data = try await model.contextAPIRequest(path: "/v1/connectors")
            let decoded = try JSONDecoder().decode(ConnectorsStatusResponse.self, from: data)
            status = decoded
            if hydrateFields {
                let fs = decoded.connectors.feishu
                feishuDomain = fs.domain
                if !fs.app_id.isEmpty { feishuAppID = fs.app_id }

            }
            if decoded.connectors.feishu.connected {
                awaitingFeishuOAuth = false
                expandFeishuManual = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startFeishuOAuth() async {
        busyConnector = "feishu"
        errorMessage = nil
        defer { busyConnector = nil }
        do {
            var payload: [String: Any] = ["domain": feishuDomain, "app_id": feishuAppID]
            if !feishuAppSecret.isEmpty { payload["app_secret"] = feishuAppSecret }
            let data = try await model.contextAPIRequest(path: "/v1/connectors/feishu/oauth/start", method: "POST", body: payload)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = obj["authorize_url"] as? String,
               let url = URL(string: urlStr) {
                feishuRedirectURI = (obj["redirect_uri"] as? String) ?? ""
                awaitingFeishuOAuth = true
                NSWorkspace.shared.open(url)
                Task {
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .seconds(2))
                        if !awaitingFeishuOAuth { break }
                        await refreshStatus(hydrateFields: false)
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncNow(_ connector: String) async {
        busyConnector = connector
        errorMessage = nil
        defer { busyConnector = nil }
        do {
            _ = try await model.contextAPIRequest(path: "/v1/connectors/sync", method: "POST", body: ["connector": connector])
            await refreshStatus(hydrateFields: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func disconnect(_ connector: String) async {
        busyConnector = connector
        errorMessage = nil
        defer { busyConnector = nil }
        do {
            _ = try await model.contextAPIRequest(path: "/v1/connectors/disconnect", method: "POST", body: ["connector": connector, "clear_data": false])
            await refreshStatus(hydrateFields: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectedMeta(label: String, count: Int, synced: Double?) -> String {
        var parts = [label, "\(count) 条"]
        if let synced {
            let fmt = DateFormatter()
            fmt.dateFormat = "MM-dd HH:mm"
            parts.append(fmt.string(from: Date(timeIntervalSince1970: synced)))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Onboarding Step

struct DesktopOnboardingConnectors: View {
    @Bindable var model: DesktopModel

    @State private var status: ConnectorsStatusResponse?
    @State private var busyConnector: String?
    @State private var errorMessage: String?

    @State private var expandFeishu = false
    @State private var feishuDomain = "feishu"
    @State private var feishuAppID = ""
    @State private var feishuAppSecret = ""
    @State private var awaitingFeishuOAuth = false
    @State private var feishuRedirectURI = ""

    private var anyConnected: Bool {
        status?.connectors.feishu.connected == true || status?.connectors.email.connected == true
    }

    var body: some View {
        VStack(spacing: 24) {
            PersonalAgentSlot(size: 64, active: busyConnector != nil, expression: anyConnected ? .settled : .present)

            Text("连接飞书与邮件")
                .font(.system(size: 28, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                onboardingRow(
                    title: "飞书",
                    connected: status?.connectors.feishu.connected == true,
                    account: status?.connectors.feishu.account_label ?? "",
                    expanded: $expandFeishu
                ) {
                    FeishuConnectorIcon(connected: status?.connectors.feishu.connected == true)
                }

                if expandFeishu {
                    VStack(spacing: 8) {
                        Picker("", selection: $feishuDomain) {
                            Text("飞书").tag("feishu")
                            Text("Lark").tag("lark")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        TextField("", text: $feishuAppID, prompt: Text(verbatim: "App ID"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        SecureField("", text: $feishuAppSecret, prompt: Text("App Secret"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                        if awaitingFeishuOAuth, !feishuRedirectURI.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text(feishuRedirectURI)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                Spacer()
                                Button("复制") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(feishuRedirectURI, forType: .string)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("授权登录") { Task { await startFeishuOAuth() } }
                                .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
                                .disabled(busyConnector != nil || feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.bottom, 12)
                }

                Rectangle().fill(MoMoPalette.borderSubtle).frame(height: 0.5)

                ComposioMailSetup(model: model, status: status?.connectors.email) {
                    await refreshStatus()
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .momoElevatedCard(cornerRadius: 18)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(MoMoPalette.failure)
                    .textSelection(.enabled)
            }

            Button(anyConnected ? "继续" : "继续配对") {
                model.advanceSetup(.pair)
            }
            .buttonStyle(DesktopSetupButton())
            .accessibilityIdentifier("onboarding.connectorsContinue")

            HStack(spacing: 24) {
                Button("返回") { model.advanceSetup(.permissions) }
                    .disabled(busyConnector != nil)
                    .accessibilityIdentifier("onboarding.connectorsBack")
                Button("稍后设置") { model.advanceSetup(.pair) }
                    .disabled(busyConnector != nil)
                    .accessibilityIdentifier("onboarding.skipConnectors")
            }
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .task { await refreshStatus() }
    }

    @ViewBuilder
    private func onboardingRow<Icon: View>(
        title: String,
        connected: Bool,
        account: String,
        expanded: Binding<Bool>,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 12) {
            icon()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                if connected, !account.isEmpty {
                    Text(account)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            if connected {
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MoMoPalette.success)
            } else {
                Button("让 MoMo 配") {
                    handoffFeishuToMoMo()
                }
                .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
                .disabled(busyConnector != nil)

                Button(expanded.wrappedValue ? "收起" : "手动") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expanded.wrappedValue.toggle()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busyConnector != nil)
            }
        }
        .padding(.vertical, 12)
    }

    private func handoffFeishuToMoMo() {
        errorMessage = nil
        let prompt = "帮我接入飞书连接器，只读同步我的飞书群聊消息和云文档。"
        if let store = model.taskStore {
            do {
                try store.enqueueIndependentMessage(prompt)
                model.advanceSetup(.completed)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = "MoMo 尚未就绪，请稍候再试。"
        }
    }

    private func refreshStatus() async {
        errorMessage = nil
        do {
            let data = try await model.contextAPIRequest(path: "/v1/connectors")
            let decoded = try JSONDecoder().decode(ConnectorsStatusResponse.self, from: data)
            status = decoded
            if decoded.connectors.feishu.connected {
                awaitingFeishuOAuth = false
                expandFeishu = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startFeishuOAuth() async {
        busyConnector = "feishu"
        errorMessage = nil
        defer { busyConnector = nil }
        do {
            var payload: [String: Any] = ["domain": feishuDomain, "app_id": feishuAppID]
            if !feishuAppSecret.isEmpty { payload["app_secret"] = feishuAppSecret }
            let data = try await model.contextAPIRequest(path: "/v1/connectors/feishu/oauth/start", method: "POST", body: payload)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let urlStr = obj["authorize_url"] as? String,
               let url = URL(string: urlStr) {
                feishuRedirectURI = (obj["redirect_uri"] as? String) ?? ""
                awaitingFeishuOAuth = true
                NSWorkspace.shared.open(url)
                Task {
                    for _ in 0..<60 {
                        try? await Task.sleep(for: .seconds(2))
                        if !awaitingFeishuOAuth { break }
                        await refreshStatus()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }


}

// MARK: - Apple Settings-Style Connector Icons

struct FeishuConnectorIcon: View {
    let connected: Bool

    private static let installedAppIcon: NSImage? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Feishu.app",
            "/Applications/Lark.app",
            "\(home)/Applications/Feishu.app",
            "\(home)/Applications/Lark.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let appIcon = Self.installedAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.08), radius: 1, y: 0.5)

                    Canvas { context, size in
                        let w = size.width
                        let h = size.height

                        // Upper teal-green Feishu/Lark wing
                        var upper = Path()
                        upper.move(to: CGPoint(x: w * 0.20, y: h * 0.22))
                        upper.addLine(to: CGPoint(x: w * 0.80, y: h * 0.45))
                        upper.addLine(to: CGPoint(x: w * 0.48, y: h * 0.62))
                        upper.addLine(to: CGPoint(x: w * 0.20, y: h * 0.48))
                        upper.closeSubpath()
                        context.fill(
                            upper,
                            with: .linearGradient(
                                Gradient(colors: [
                                    Color(red: 0.00, green: 0.84, blue: 0.73),
                                    Color(red: 0.00, green: 0.75, blue: 0.67),
                                ]),
                                startPoint: CGPoint(x: w * 0.2, y: h * 0.2),
                                endPoint: CGPoint(x: w * 0.8, y: h * 0.5)
                            )
                        )

                        // Lower signature blue Feishu/Lark wing
                        var lower = Path()
                        lower.move(to: CGPoint(x: w * 0.20, y: h * 0.48))
                        lower.addLine(to: CGPoint(x: w * 0.82, y: h * 0.52))
                        lower.addLine(to: CGPoint(x: w * 0.36, y: h * 0.80))
                        lower.addLine(to: CGPoint(x: w * 0.20, y: h * 0.68))
                        lower.closeSubpath()
                        context.fill(
                            lower,
                            with: .linearGradient(
                                Gradient(colors: [
                                    Color(red: 0.20, green: 0.44, blue: 1.00),
                                    Color(red: 0.08, green: 0.34, blue: 0.94),
                                ]),
                                startPoint: CGPoint(x: w * 0.2, y: h * 0.5),
                                endPoint: CGPoint(x: w * 0.8, y: h * 0.8)
                            )
                        )

                        // Inner overlap fold
                        var fold = Path()
                        fold.move(to: CGPoint(x: w * 0.20, y: h * 0.48))
                        fold.addLine(to: CGPoint(x: w * 0.56, y: h * 0.50))
                        fold.addLine(to: CGPoint(x: w * 0.44, y: h * 0.61))
                        fold.closeSubpath()
                        context.fill(fold, with: .color(Color(red: 0.07, green: 0.24, blue: 0.61)))
                    }
                    .frame(width: 24, height: 24)
                }
                .frame(width: 28, height: 28)
            }

            if connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 28, height: 28)
    }
}

struct MailConnectorIcon: View {
    let connected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.29, green: 0.71, blue: 1.00),
                                Color(red: 0.09, green: 0.41, blue: 0.95),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)

                Image(systemName: "envelope.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            if connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// Both entry points resume the same pending connection after the browser handoff.
private struct ComposioMailSetup: View {
    let model: DesktopModel
    let status: ConnectorsStatusResponse.EmailStatus?
    let refresh: () async -> Void

    private enum Action { case start, check, sync, disconnect, updateKey }

    @State private var expanded = false
    @State private var provider = "gmail"
    @State private var key = ""
    @State private var replaceKey = false
    @State private var busy = false
    @State private var error: String?
    @State private var polling = true
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MailConnectorIcon(connected: status?.connected == true)
                VStack(alignment: .leading) {
                    Text("邮件").font(.headline)
                    if let status, status.connected {
                        Text("\(status.account_label) · \(status.item_count) 封").font(.caption)
                    }
                }
                Spacer()
                if let status, status.connected {
                    Button("同步") { Task { await perform(.sync) } }
                    Menu {
                        Button("更换 Composio API key") { replaceKey.toggle() }
                        Button("断开连接", role: .destructive) { Task { await perform(.disconnect) } }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("邮箱连接选项")
                } else if status != nil, status?.pending != true {
                    Button(expanded ? "收起" : "连接邮箱") { expanded.toggle() }
                        .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
                }
            }
            if status?.needs_reconnect == true {
                Text("旧邮箱连接需要重新授权。已同步的邮件仍可搜索。").font(.caption)
            }
            if status?.pending == true {
                Label("请在浏览器完成邮箱授权", systemImage: "arrow.up.right.square")
                HStack {
                    Button("打开授权页") { Task { await perform(.start) } }
                    Button("检查连接") { Task { await perform(.check) } }
                    Button("取消连接") { Task { await perform(.disconnect) } }
                    Button("更换 API key") { replaceKey.toggle() }
                }
            } else if expanded, status?.connected != true {
                Picker("邮箱服务", selection: $provider) {
                    Text("Gmail").tag("gmail")
                    Text("Outlook").tag("outlook")
                }
                .pickerStyle(.segmented)
                Text("Composio 保管邮箱授权，并代理读取最近 7 天的收件箱邮件。")
                    .font(.caption).foregroundStyle(.secondary)
                if status?.has_api_key != true || replaceKey {
                    Link("获取 Composio 项目 API key", destination: URL(string: "https://dashboard.composio.dev/~/project/settings/api-keys")!)
                    SecureField("Composio 项目 API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Button("更换 Composio API key") { replaceKey = true }
                        .buttonStyle(.link)
                }
                Button("在浏览器中授权") { Task { await perform(.start) } }
                    .disabled((replaceKey || status?.has_api_key != true) && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if replaceKey, status?.connected == true || status?.pending == true {
                SecureField("同一 Composio 项目的新 API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("保存 API key") { Task { await perform(.updateKey) } }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if status == nil {
                Button("重新读取连接状态") { Task { await refresh() } }
            }
            if busy { ProgressView().controlSize(.small).accessibilityLabel("正在联系邮箱服务") }
            if let message = error ?? status?.last_error {
                Text(message).foregroundStyle(MoMoPalette.failure).font(.caption).textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.leading)
        .disabled(busy || checking)
        .task(id: status?.pending) {
            guard status?.pending == true else { return }
            polling = true
            for _ in 0..<60 {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard polling, !Task.isCancelled else { return }
                if !busy { await perform(.check, automatic: true) }
            }
        }
    }

    @MainActor
    private func perform(_ action: Action, automatic: Bool = false) async {
        guard !busy else { return }
        if checking { return }
        if action == .check { checking = true }
        if !automatic { busy = true }
        defer {
            if action == .check { checking = false }
            if !automatic { busy = false }
        }
        error = nil
        do {
            switch action {
            case .start:
                let selected = status.flatMap { $0.pending ? $0.provider : nil } ?? provider
                var payload = ["provider": selected]
                if !key.isEmpty { payload["api_key"] = key }
                let data = try await model.contextAPIRequest(path: "/v1/connectors/email/oauth/start", method: "POST", body: payload)
                struct LinkResponse: Decodable { let authorize_url: URL }
                let link = try JSONDecoder().decode(LinkResponse.self, from: data)
                key = ""
                replaceKey = false
                polling = true
                if !NSWorkspace.shared.open(link.authorize_url) { error = "无法打开浏览器，请重试打开授权页。" }
            case .check:
                let data = try await model.contextAPIRequest(path: "/v1/connectors/email/oauth/check", method: "POST", body: [:])
                struct Connection: Decodable { let connected: Bool }
                if try JSONDecoder().decode(Connection.self, from: data).connected { expanded = false }
            case .sync:
                let data = try await model.contextAPIRequest(path: "/v1/connectors/sync", method: "POST", body: ["connector": "email"])
                struct SyncResult: Decodable {
                    struct MailResult: Decodable { let error: String? }
                    let results: [String: MailResult]
                }
                error = try JSONDecoder().decode(SyncResult.self, from: data).results["email"]?.error
            case .updateKey:
                _ = try await model.contextAPIRequest(path: "/v1/connectors/email/key", method: "POST", body: ["api_key": key])
                key = ""
                replaceKey = false
                polling = true
            case .disconnect:
                _ = try await model.contextAPIRequest(path: "/v1/connectors/disconnect", method: "POST", body: ["connector": "email"])
                expanded = false
                key = ""
                replaceKey = false
            }
        } catch {
            self.error = error.localizedDescription
            polling = false
        }
        await refresh()
    }
}
