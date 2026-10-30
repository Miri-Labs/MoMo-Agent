import SwiftUI

extension DesktopModel {
    var companionState: DesktopCompanionState {
        DesktopCompanionState(prepared: setupStep == .completed, online: status?.agentOnline == true && taskStore?.connectionState == .ready,
                              runs: taskStore?.sharedRuns ?? [], work: taskStore?.backgroundWork ?? [], tasks: taskStore?.tasks ?? [])
    }
}

struct DesktopCompanionCard: View {
    let model: DesktopModel
    let openChat: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void
    let pin: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduced
    @State private var showAll = false
    private var state: DesktopCompanionState { model.companionState }

    private var statusColor: Color {
        if !state.prepared || !state.online { return .white.opacity(0.35) }
        if state.needsAttention { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PersonalAgentSlot(size: 44, active: state.working,
                                  expression: !state.online || state.needsAttention ? .concerned : state.working ? .working : .present)
                VStack(alignment: .leading, spacing: 4) {
                    PhoneBrandWordmark(.momo, size: 20)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(state.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62))
                    }
                }
                Spacer(minLength: 0)
            }

            if model.desktopHost?.humanHasControl == true {
                CompanionControlBanner {
                    do { try model.desktopHost?.returnControl() }
                    catch { model.desktopFailure = error.localizedDescription }
                }
            }
            if let failure = model.desktopFailure {
                Text(failure).font(.caption).foregroundStyle(Color.red.opacity(0.9))
            }

            if !state.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("当前任务").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if state.items.count > 3 {
                            CompanionSmallButton(title: showAll ? "收起" : "全部 \(state.items.count) 项",
                                                 icon: showAll ? "chevron.up" : "chevron.down") {
                                pin(); showAll.toggle()
                            }
                        }
                    }
                    if showAll && state.items.count > 3 {
                        ScrollView {
                            taskRows
                        }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: 228)
                    } else {
                        taskRows
                    }
                }
            }

            CompanionPrimaryButton(title: state.prepared ? "和 MoMo 聊聊" : "开始设置", action: openChat)
                .accessibilityIdentifier("companion.openChat")

            VStack(spacing: 10) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).accessibilityHidden(true)
                HStack {
                    CompanionFooterButton(title: "设置…", icon: "gearshape", action: openSettings)
                        .accessibilityIdentifier("companion.settings")
                    Spacer()
                    CompanionFooterButton(title: "退出", icon: "power", action: quit)
                        .accessibilityIdentifier("companion.quit")
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .frame(maxWidth: .infinity).foregroundStyle(.white).background(.black)
        .environment(\.colorScheme, .dark)
        .animation(reduced ? nil : .easeOut(duration: 0.16), value: showAll)
    }

    private var taskRows: some View {
        VStack(spacing: 6) {
            ForEach(showAll ? state.items : Array(state.items.prefix(3))) { item in
                CompanionTaskRow(item: item, online: state.online, action: openChat)
                    .accessibilityIdentifier("companion.task.\(item.id)")
            }
        }
    }
}

private struct CompanionTaskRow: View {
    let item: DesktopCompanionState.Item
    let online: Bool
    let action: () -> Void
    @State private var hovered = false

    private var urgent: Bool { online && item.phase >= .waiting }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: online ? item.phase.symbol : "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(urgent ? .orange : .white.opacity(0.72))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(online ? item.phase.label : String(localized: "待同步"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(urgent ? .orange : .white.opacity(0.5))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovered ? 0.75 : 0.3))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 12).frame(height: 38)
            .background(.white.opacity(hovered ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                urgent ? Color.orange.opacity(0.35) : .white.opacity(hovered ? 0.18 : 0.07), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(item.title)
    }
}

private struct CompanionPrimaryButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill").font(.system(size: 12)).accessibilityHidden(true)
                Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 14).frame(height: 40)
            .background(.white.opacity(hovered ? 1.0 : 0.92), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct CompanionFooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium)).accessibilityHidden(true)
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(hovered ? 0.12 : 0), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct CompanionSmallButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                Image(systemName: icon).font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(hovered ? 0.9 : 0.55))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(hovered ? 0.12 : 0.05), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct CompanionControlBanner: View {
    let returnControl: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").font(.system(size: 11)).foregroundStyle(.orange).accessibilityHidden(true)
            Text("电脑当前由你控制").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            Button(action: returnControl) {
                Text("交还 MoMo")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(hovered ? 0.24 : 0.15), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
    }
}
