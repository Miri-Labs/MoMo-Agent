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
        DesktopSettingsGroup("网络代理") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tailscale").font(.system(size: 13))
                    Spacer()
                    Menu {
                        Picker("网络代理", selection: $draft.mode) {
                            ForEach(TailnetProxySettings.Mode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.inline).labelsHidden()
                    } label: {
                        HStack(spacing: 12) {
                            Text(draft.mode.title).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button).buttonStyle(DesktopSettingsButtonStyle()).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                    .frame(width: 160).accessibilityLabel("网络代理").accessibilityValue(draft.mode.title)
                    .accessibilityIdentifier("settings.proxyMode")
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
                        }.buttonStyle(DesktopSettingsButtonStyle()).disabled(applying).accessibilityIdentifier("settings.applyProxy")
                    }
                }
                if let message = error ?? model.tailnet.proxySettingsError {
                    Text(message).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure)
                        .textSelection(.enabled).accessibilityIdentifier("settings.proxyError")
                }
            }
            .padding(.vertical, 12)
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
