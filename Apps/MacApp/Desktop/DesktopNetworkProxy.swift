import SwiftUI

struct DesktopNetworkProxy: View {
    let model: DesktopModel
    // Deliberate editing draft: applying is explicit; navigation discards edits.
    @State private var draft: TailnetProxySettings
    @State private var applying = false
    @State private var error: String?

    init(model: DesktopModel) {
        self.model = model
        _draft = State(initialValue: model.tailnet.proxySettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网络代理").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Text("Tailscale").font(.system(size: 14, weight: .medium))
                Spacer()
                Picker("网络代理", selection: $draft.mode) {
                    ForEach(TailnetProxySettings.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                }.labelsHidden().frame(width: 160).accessibilityIdentifier("settings.proxyMode")
            }
            if draft.mode == .manual {
                TextField("如 http://127.0.0.1:7890", text: $draft.address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("代理地址").accessibilityIdentifier("settings.proxyAddress")
                    .onSubmit { apply() }
            }
            if draft != model.tailnet.proxySettings || model.tailnet.proxySettingsError != nil || applying {
                HStack {
                    Spacer()
                    Button(action: apply) {
                        HStack(spacing: 6) {
                            if applying { ProgressView().controlSize(.small) }
                            Text(applying ? "正在应用" : "应用")
                        }.frame(minWidth: 74)
                    }.disabled(applying).accessibilityIdentifier("settings.applyProxy")
                }
            }
            if let message = error ?? model.tailnet.proxySettingsError {
                Text(message).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure)
                    .textSelection(.enabled).accessibilityIdentifier("settings.proxyError")
            }
        }
        .disabled(applying)
        .onChange(of: draft) { _, _ in error = nil }
    }

    private func apply() {
        guard !applying else { return }
        applying = true; error = nil
        Task { @MainActor in
            defer { applying = false }
            do {
                try await model.applyNetworkProxy(draft)
                draft = model.tailnet.proxySettings
            } catch { self.error = error.localizedDescription }
        }
    }
}
