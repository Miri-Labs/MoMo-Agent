import SwiftUI
import MoMoAgentClient

struct ChatModeSettings: View {
    let store: RemoteTaskStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var mode: ChatMode?
    @State private var busy = false
    @State private var failure: (message: String, selection: ChatMode?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let mode {
                Picker("对话模式", selection: Binding(get: { mode }, set: { choice in
                    guard choice != mode else { return }
                    Task { await update(choice) }
                })) {
                    Text("聊天模式").tag(ChatMode.standard)
                    Text("创作模式").tag(ChatMode.creator)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(macOS)
                .fixedSize(horizontal: true, vertical: false)
                #endif
                .disabled(busy)
                .accessibilityIdentifier("settings.chatMode")
            } else if failure == nil || busy {
                ProgressView("对话模式").controlSize(.small)
            }
            Text("在创作模式下，可以让 MoMo 添加个人扩展。扩展保存在 Mac 上。")
                .font(.footnote).foregroundStyle(.secondary)
            if let failure {
                HStack {
                    Text(verbatim: failure.message).font(.footnote)
                    Button("重试") { Task { await update(failure.selection) } }.disabled(busy)
                }
            }
        }
        .task(id: ObjectIdentifier(store)) { await update() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await update() } }
        }
    }

    @MainActor private func update(_ selection: ChatMode? = nil) async {
        guard !busy else { return }
        busy = true
        let previous = mode
        if let selection { mode = selection }
        failure = nil
        defer { busy = false }
        do {
            mode = try await store.chatMode(setting: selection)
        } catch {
            mode = previous
            if error is CancellationError { return }
            if case AgentClientError.http(status: 404, code: _, message: _, retryAfter: _) = error {
                failure = (String(localized: "请更新 Mac 上的 MoMo 以使用创作模式。"), selection)
            } else {
                failure = (error.localizedDescription, selection)
            }
        }
    }
}
