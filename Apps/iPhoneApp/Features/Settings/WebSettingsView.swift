import SwiftUI
import Observation
import MoMoWeb

@MainActor @Observable
final class WebSettingsModel {
    let access: WebAccess
    var value = WebSettings()
    var loaded = false
    var changing = false
    var failure: String?
    init(access: WebAccess) { self.access = access }
    func refresh() async {
        do { value = try await access.settings(); failure = nil; loaded = true }
        catch { failure = WebError.storage.localizedDescription }
    }
    func update(enabled: Bool, search: WebProvider?, fetch: WebProvider?) async {
        guard loaded, !changing else { return }
        changing = true; defer { changing = false }
        do {
            value = try await access.update(enabled: enabled, search: search, fetch: fetch, revision: value.revision)
            failure = nil
        } catch { failure = Self.message(error) }
    }
    func cleanup() async {
        guard !changing else { return }; changing = true; defer { changing = false }
        do { value = try await access.retryCredentialCleanup(); failure = nil }
        catch { failure = Self.message(error) }
    }
    static func message(_ error: Error) -> String {
        if let error = error as? WebError { return error.localizedDescription }
        if error is CancellationError { return WebError.cancelled.localizedDescription }
        return WebError.storage.localizedDescription
    }
}

struct WebConnectionOptions: View {
    @State private var model: WebSettingsModel
    @State private var editing: WebProvider?
    @State private var expanded = false
    @Environment(\.scenePhase) private var scenePhase

    init(access: WebAccess) { _model = State(initialValue: WebSettingsModel(access: access)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "globe").font(.system(size: 21)).frame(width: 28).accessibilityHidden(true)
                Text("联网服务").phoneText(.body)
                Spacer(minLength: 8)
                Button(expanded ? String(localized: "收起") : String(localized: "配置")) {
                    expanded.toggle()
                    if !expanded { editing = nil }
                }
                .phoneText(.metadata).frame(minWidth: 44, minHeight: 44).disabled(!model.loaded)
                .accessibilityIdentifier("connections.web.configure")
                Toggle("联网服务", isOn: Binding(get: { model.value.enabled }, set: { enabled in
                    if enabled { expanded = true }
                    Task { await model.update(enabled: enabled, search: model.value.searchProvider, fetch: model.value.fetchProvider) }
                }))
                .labelsHidden().tint(MoMoPalette.ink).disabled(!model.loaded || editing != nil)
                .accessibilityIdentifier("web.enabled")
            }.frame(minHeight: 62)

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("网页搜索")
                        Spacer(minLength: 8)
                        Picker("网页搜索", selection: Binding(get: { model.value.searchProvider }, set: { provider in
                            Task { await model.update(enabled: model.value.enabled, search: provider, fetch: model.value.fetchProvider) }
                        })) { serviceOptions }
                        .pickerStyle(.menu).labelsHidden().accessibilityIdentifier("web.searchProvider")
                    }.frame(minHeight: 44).disabled(editing != nil)
                    HStack {
                        Text("网页读取")
                        Spacer(minLength: 8)
                        Picker("网页读取", selection: Binding(get: { model.value.fetchProvider }, set: { provider in
                            Task { await model.update(enabled: model.value.enabled, search: model.value.searchProvider, fetch: provider) }
                        })) { serviceOptions }
                        .pickerStyle(.menu).labelsHidden().accessibilityIdentifier("web.fetchProvider")
                    }.frame(minHeight: 44).disabled(editing != nil)

                    ForEach(WebProvider.allCases) { provider in
                        Button { editing = editing == provider ? nil : provider } label: {
                            HStack {
                                Text(provider.title)
                                Spacer(minLength: 8)
                                Text(model.value.connection(provider) == nil ? String(localized: "未配置") : String(localized: "已配置"))
                                    .foregroundStyle(MoMoPalette.muted)
                                Image(systemName: editing == provider ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .medium)).accessibilityHidden(true)
                            }.frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityValue(editing == provider ? String(localized: "已展开") : String(localized: "已收起"))
                        .accessibilityIdentifier("web.connection.\(provider.rawValue)")
                        if editing == provider {
                            WebConnectionView(model: model, provider: provider, editing: $editing)
                        }
                    }
                    Text("搜索词与网页地址会发送到所选服务，按服务商计费。")
                        .phoneText(.caption).foregroundStyle(MoMoPalette.muted).padding(.vertical, 8)
                    if model.value.needsCredentialCleanup {
                        Text("旧密钥已停用，待清理。")
                        Button("重试清理旧密钥") { Task { await model.cleanup() } }.frame(minHeight: 44)
                    }
                }.phoneText(.metadata).padding(.leading, 42)
                    .disabled(!model.loaded || model.changing)
            }

            if let failure = model.failure {
                Text(failure).phoneText(.caption).foregroundStyle(MoMoPalette.failure)
                    .accessibilityIdentifier("web.failure")
                Button("重新读取配置") { editing = nil; Task { await model.refresh() } }
                    .phoneText(.metadata).frame(minHeight: 44)
            } else if !model.loaded {
                ProgressView("正在读取联网配置").padding(.vertical, 8)
            }
        }
        .buttonStyle(.plain).foregroundStyle(MoMoPalette.ink)
        .disabled(model.changing)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, editing == nil, !model.changing { Task { await model.refresh() } }
        }
        .accessibilityIdentifier("connections.web")
    }
    @ViewBuilder private var serviceOptions: some View {
        Text("未选择").tag(WebProvider?.none)
        ForEach(WebProvider.allCases) { provider in
            Text(provider.title).tag(Optional(provider)).disabled(model.value.connection(provider) == nil)
        }
    }
}

private struct WebConnectionView: View {
    let model: WebSettingsModel
    @State private var draft: WebConnectionDraft
    @State private var operation: Operation?
    @State private var result: WebConnectionTest?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?
    @State private var showRemove = false
    @Binding private var editing: WebProvider?
    private enum Operation { case testing, saving, removing }
    init(model: WebSettingsModel, provider: WebProvider, editing: Binding<WebProvider?>) {
        self.model = model; _editing = editing; _draft = State(initialValue: .init(provider: provider, settings: model.value))
    }
    private var isSaved: Bool { model.value.connection(draft.provider) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SecureField(isSaved ? String(localized: "已保存 · 留空保留原密钥") : String(localized: "粘贴你的 API Key"), text: $draft.apiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("web.apiKey")
            Link("获取 API Key", destination: draft.provider.keyURL).frame(minHeight: 44)
            TextField("HTTPS 服务根地址", text: $draft.address, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .textFieldStyle(.roundedBorder).accessibilityLabel("服务根地址")
                .accessibilityIdentifier("web.address")
            Text("密钥保存在系统钥匙串；更换服务地址需重新填写密钥。")
                .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            Button { run(.testing) } label: {
                HStack { Text("测试搜索与读取"); Spacer(); if operation == .testing { ProgressView() } }
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("web.test")
            Text("测试搜索 Swift programming language 并读取 Swift 官方文档；各 1 次请求，按服务商计费。")
                .phoneText(.caption).foregroundStyle(MoMoPalette.muted)
            if let result {
                testRow(String(localized: "搜索"), result.search, unit: String(localized: "个结果"))
                testRow(String(localized: "读取"), result.fetch, unit: String(localized: "字符"))
            }
            if let failure {
                Text(failure).foregroundStyle(MoMoPalette.failure).accessibilityIdentifier("web.connectionFailure")
            }
            Button { run(.saving) } label: {
                HStack { Text("保存并启用"); Spacer(); if operation == .saving { ProgressView() } }
                    .frame(minHeight: 44).contentShape(Rectangle())
            }.accessibilityIdentifier("web.save")
            if isSaved {
                Button("移除配置", role: .destructive) { showRemove = true }
                    .frame(minHeight: 44).accessibilityIdentifier("web.remove")
            }
        }
        .padding(.vertical, 12).disabled(operation != nil)
        .onChange(of: draft.apiKey) { result = nil; failure = nil }
        .onChange(of: draft.address) { result = nil; failure = nil }
        .onDisappear { task?.cancel(); draft.apiKey = "" }
        .confirmationDialog("移除 \(draft.provider.title) 的联网配置？", isPresented: $showRemove) {
            Button("移除", role: .destructive) { run(.removing) }
        } message: { Text("使用这家服务的搜索和网页读取会停用，模型服务配置不受影响。") }
    }
    private func testRow(_ title: String, _ result: Result<Int, WebError>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch result {
            case .success(let count):
                Label("\(title)：请求成功 · \(count) \(unit)", systemImage: "checkmark.circle")
                    .foregroundStyle(MoMoPalette.success)
            case .failure(let error):
                Label("\(title)：\(error.localizedDescription)", systemImage: "exclamationmark.circle")
                    .foregroundStyle(MoMoPalette.failure)
            }
        }.phoneText(.metadata).accessibilityIdentifier("web.test.\(title)")
    }
    private func run(_ action: Operation) {
        guard operation == nil, !model.changing else { return }; operation = action; failure = nil
        if action != .testing { model.changing = true }
        task = Task { @MainActor in
            defer { operation = nil; if action != .testing { model.changing = false } }
            do {
                switch action {
                case .testing:
                    let value = try await model.access.test(draft)
                    try Task.checkCancellation(); result = value
                case .saving:
                    model.value = try await model.access.save(draft)
                    draft.apiKey = ""; model.failure = nil; editing = nil
                case .removing:
                    model.value = try await model.access.remove(draft.provider, revision: draft.revision)
                    draft.apiKey = ""; model.failure = nil; editing = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure = WebSettingsModel.message(error)
            }
        }
    }
}
