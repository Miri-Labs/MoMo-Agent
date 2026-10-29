import SwiftUI
import MoMoArchive

struct SpeakerFeedbackMenu: View {
    let speaker: String?
    let attribution: SpeakerAttribution?
    let source: SourceReference
    var additionalSources: [SourceReference] = []
    let archive: ArchiveStore
    let changed: () async -> Void
    @State private var naming = false
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?

    private var displayName: String {
        guard let speaker, speaker != String(localized: "说话人未确定") else { return String(localized: "未确认") }
        return speaker
    }

    var body: some View {
        Menu {
            Button("这是我", systemImage: "person.crop.circle.badge.checkmark") { correct(.owner) }
            Button("这不是我", systemImage: "person.crop.circle.badge.xmark") { correct(.notOwner) }
            Button("命名说话人", systemImage: "pencil") { name = ""; naming = true }
            if attribution != nil {
                Button("撤销本段标记", systemImage: "arrow.uturn.backward") { correct(.clear) }
            }
            if attribution?.canLearn != true {
                Text("此段仅修改说话人标记，不用于声纹学习。")
            }
        } label: {
            HStack(spacing: 4) {
                Text(displayName).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.medium)).accessibilityHidden(true)
            }
            .phoneText(.caption)
            .foregroundStyle(attribution?.confirmed == true ? MoMoPalette.ink : MoMoPalette.muted)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(MoMoPalette.ink.opacity(0.045), in: Capsule())
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityLabel(Text("说话人"))
        .accessibilityValue(Text(displayName))
        .accessibilityIdentifier("transcript.speaker.\(source.spanID)")
        .alert("命名说话人", isPresented: $naming) {
            TextField("姓名", text: $name)
            Button("保存") { correct(.person(name)) }
            Button("取消", role: .cancel) { }
        } message: { Text(attribution?.canLearn == true ? "确认这段声音的主人，后续录音将使用这份声纹匹配。" : "此段仅修改说话人标记，不用于声纹学习。") }
        .alert("声纹未更新", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func correct(_ feedback: SpeakerFeedback) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do { try await archive.correctSpeakers([source] + additionalSources, feedback: feedback); await changed() }
            catch { failure = error.localizedDescription }
        }
    }
}
