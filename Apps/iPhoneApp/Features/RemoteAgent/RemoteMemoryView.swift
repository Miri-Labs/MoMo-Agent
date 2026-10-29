import SwiftUI
import MoMoAgentClient

struct RemoteMemoryView: View {
    let sync: PhoneContextSync
    @State private var forgetting: ContextMemory?
    @State private var showingSync = false
    private var memories: [ContextMemory] { sync.memories.filter { $0.status != "forgotten" } }
    private var hasSyncDetails: Bool { sync.lastSynced != nil || sync.memoryPending > 0 || sync.memoryNeedsReview > 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PhoneSettingsSurface {
                    if hasSyncDetails {
                        DisclosureGroup(isExpanded: $showingSync) {
                            VStack(alignment: .leading, spacing: 12) {
                                if let date = sync.lastSynced { PhoneSettingsValueRow(title: "最近同步", value: Text(date, style: .relative)) }
                                if sync.memoryPending > 0 { Text("\(sync.memoryPending) 批录音待整理") }
                                if sync.memoryNeedsReview > 0 { Text("\(sync.memoryNeedsReview) 份录音需核对，原文仍保留。") }
                            }.phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                        } label: {
                            HStack {
                                Text("录音同步").phoneText(.body)
                                Spacer()
                                Text(sync.isSyncing ? String(localized: "正在同步") : sourceStatus).phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                            }
                        }.padding(18).accessibilityIdentifier("remote.memorySyncDetails")
                    } else {
                        PhoneSettingsLinkRow(title: "录音同步", value: sync.isSyncing ? String(localized: "正在同步") : sourceStatus, disclosure: false)
                            .accessibilityIdentifier("remote.memorySyncStatus")
                    }
                }
                if sync.hasLegacyChanges {
                    Text("旧版待同步修改已保留，请核对当前记忆后重新修改。")
                        .phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                if let failure = sync.failure { Text(failure).phoneText(.metadata).foregroundStyle(MoMoPalette.failure) }
                if sync.memoryNeedsReview > 0 && !showingSync {
                    Text("\(sync.memoryNeedsReview) 份录音整理需核对").phoneText(.metadata).foregroundStyle(MoMoPalette.muted)
                }
                ForEach(memories) { memory in
                    PhoneSettingsSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Spacer()
                                Menu {
                                    Button("忘记这条记忆", role: .destructive) { forgetting = memory }
                                        .accessibilityIdentifier("remote.forgetMemory")
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                                }.accessibilityLabel("记忆操作").accessibilityIdentifier("remote.memoryActions")
                            }
                            ClientMemoryContent(memory: memory)
                        }.padding(18)
                    }
                }
                if memories.isEmpty {
                    Text(sync.isSyncing ? "正在读取记忆…" : "还没有记忆。告诉 MoMo 想记住的事。")
                        .phoneText(.body).foregroundStyle(MoMoPalette.muted)
                        .accessibilityIdentifier("remote.memoryEmpty")
                }
            }.padding(24)
        }
        .phonePageSurface().tint(MoMoPalette.ink)
        .navigationTitle("记忆").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("同步录音与记忆", systemImage: "arrow.clockwise") { Task { await sync.refresh() } }
                    .disabled(sync.isSyncing).accessibilityIdentifier("remote.syncMemory")
            }
        }
        .confirmationDialog("忘记这条记忆？", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            if let memory = forgetting {
                Button("忘记", role: .destructive) { Task { await sync.forget(memory) }; forgetting = nil }
            }
        } message: { Text("连接 Mac 后删除这条记忆。原始录音与聊天记录仍保留。") }
        .task { await sync.refresh() }
    }

    private var sourceStatus: String {
        if sync.pendingSources > 0 { return String(localized: "\(sync.pendingSources) 份待送达") }
        return sync.lastSourcesSent == nil ? String(localized: "尚未同步") : String(localized: "已送达 Mac")
    }
}
