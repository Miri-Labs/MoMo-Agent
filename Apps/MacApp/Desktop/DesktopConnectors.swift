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
        let preset: String
        let host: String
        let port: Int
        let username: String
        let has_password: Bool
        let folder: String
        let sync_days: Int
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

    @State private var expandEmailManual = false
    @State private var expandEmailAdvanced = false
    @State private var emailUsername = ""
    @State private var emailPassword = ""
    @State private var emailHost = ""
    @State private var emailPort = "993"
    @State private var emailFolder = "INBOX"
    @State private var emailSyncDays = 7

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
                emailRow
                if expandEmailManual {
                    emailManualFields
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
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 16))
                .foregroundStyle(connected ? Color.green : .secondary)
                .frame(width: 24)

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
                    Button("让 MoMo 排查") { askMoMoToConfigure("feishu", reconnect: true) }
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
                    askMoMoToConfigure("feishu", reconnect: false)
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

    // MARK: - Email

    private var emailRow: some View {
        let em = status?.connectors.email
        let connected = em?.connected == true
        return HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 16))
                .foregroundStyle(connected ? Color.green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("邮件")
                    .font(.system(size: 14, weight: .medium))
                if connected, let em {
                    Text(connectedMeta(label: em.account_label, count: em.item_count, synced: em.last_synced))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if let err = em?.last_error, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(MoMoPalette.failure)
                        .lineLimit(1)
                }
            }

            Spacer()

            if connected {
                Button("同步") { Task { await syncNow("email") } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busyConnector != nil)

                Menu {
                    Button("让 MoMo 排查") { askMoMoToConfigure("email", reconnect: true) }
                    Button("修改配置") { expandEmailManual.toggle() }
                    Divider()
                    Button("断开连接", role: .destructive) { Task { await disconnect("email") } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button("让 MoMo 帮我配") {
                    askMoMoToConfigure("email", reconnect: false)
                }
                .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
                .disabled(busyConnector != nil)

                Button(expandEmailManual ? "收起" : "手动") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandEmailManual.toggle()
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
    private var emailManualFields: some View {
        let em = status?.connectors.email
        TextField("邮箱", text: $emailUsername, prompt: Text(verbatim: "you@example.com"))
            .textFieldStyle(.roundedBorder)

        SecureField("密码", text: $emailPassword, prompt: Text(em?.has_password == true ? "已保存" : "应用专用密码 / 授权码"))
            .textFieldStyle(.roundedBorder)

        DisclosureGroup("高级", isExpanded: $expandEmailAdvanced) {
            HStack(spacing: 8) {
                TextField("IMAP", text: $emailHost, prompt: Text(verbatim: "自动识别"))
                    .textFieldStyle(.roundedBorder)
                TextField("端口", text: $emailPort, prompt: Text(verbatim: "993"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
            }
            HStack(spacing: 10) {
                TextField("文件夹", text: $emailFolder, prompt: Text(verbatim: "INBOX"))
                    .textFieldStyle(.roundedBorder)
                Stepper("近 \(emailSyncDays) 天", value: $emailSyncDays, in: 1...30)
                    .font(.system(size: 12))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)

        HStack {
            Spacer()
            Button("连接") {
                Task { await saveEmailConnector() }
            }
            .buttonStyle(DesktopSetupButton(filled: true, minimumHeight: 28, fontSize: 12))
            .disabled(busyConnector != nil || emailUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: - AI-Native Handoff

    private func askMoMoToConfigure(_ connector: String, reconnect: Bool) {
        errorMessage = nil
        guard let store = model.taskStore else {
            errorMessage = "MoMo 尚未在线，请稍候再试。"
            return
        }
        let prompt: String
        switch (connector, reconnect) {
        case ("feishu", false):
            prompt = "帮我接入飞书连接器，只读同步我的飞书消息和云文档。请一步步带我完成。"
        case ("feishu", true):
            prompt = "帮我检查一下飞书连接器的状态和同步情况，有问题的话顺手帮我修好。"
        case ("email", false):
            prompt = "帮我接入我的邮箱连接器，只读同步近期邮件。请一步步带我完成。"
        default:
            prompt = "帮我检查一下邮箱连接器的状态和同步情况，有问题的话顺手帮我修好。"
        }
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
        do {
            let data = try await model.contextAPIRequest(path: "/v1/connectors")
            let decoded = try JSONDecoder().decode(ConnectorsStatusResponse.self, from: data)
            status = decoded
            if hydrateFields {
                let fs = decoded.connectors.feishu
                feishuDomain = fs.domain
                if !fs.app_id.isEmpty { feishuAppID = fs.app_id }
                let em = decoded.connectors.email
                if !em.username.isEmpty { emailUsername = em.username }
                if !em.host.isEmpty { emailHost = em.host }
                emailPort = String(em.port)
                if !em.folder.isEmpty { emailFolder = em.folder }
                emailSyncDays = max(1, min(30, em.sync_days))
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

    private func saveEmailConnector() async {
        busyConnector = "email"
        errorMessage = nil
        defer { busyConnector = nil }
        do {
            var payload: [String: Any] = [
                "username": emailUsername,
                "folder": emailFolder,
                "sync_days": emailSyncDays,
                "enabled": true,
            ]
            let trimmedHost = emailHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedHost.isEmpty {
                payload["host"] = trimmedHost
                payload["port"] = Int(emailPort) ?? 993
            }
            if !emailPassword.isEmpty { payload["password"] = emailPassword }
            _ = try await model.contextAPIRequest(path: "/v1/connectors/email/configure", method: "POST", body: payload)
            emailPassword = ""
            expandEmailManual = false
            await refreshStatus(hydrateFields: false)
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
