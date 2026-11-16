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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showAll = false

    private func statusColor(for state: DesktopCompanionState) -> Color {
        if !state.prepared || !state.online { return .white.opacity(0.35) }
        if state.needsAttention { return .orange }
        return .green
    }

    var body: some View {
        let state = model.companionState
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PersonalAgentSlot(size: 44, active: state.working,
                                  expression: !state.online || state.needsAttention ? .concerned : state.working ? .working : .present)
                VStack(alignment: .leading, spacing: 3) {
                    PhoneBrandWordmark(.momo, size: 19)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor(for: state)).frame(width: 6, height: 6).accessibilityHidden(true)
                        Text(state.subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.64))
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
                        Text("当前任务").font(.system(size: 11, weight: .medium)).tracking(0.06).foregroundStyle(.white.opacity(0.48))
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
                            taskRows(for: state)
                        }.scrollBounceBehavior(.basedOnSize).frame(maxHeight: 228)
                    } else {
                        taskRows(for: state)
                    }
                }
            }

            CompanionPrimaryButton(title: state.prepared ? "和 MoMo 聊聊" : "开始设置", action: openChat)
                .accessibilityIdentifier("companion.openChat")

            VStack(spacing: 9) {
                Rectangle().fill(.white.opacity(0.09)).frame(height: 0.5).accessibilityHidden(true)
                HStack {
                    CompanionFooterButton(title: "设置…", icon: "gearshape", action: openSettings)
                        .accessibilityIdentifier("companion.settings")
                    Spacer()
                    CompanionFooterButton(title: "退出", icon: "power", action: quit)
                        .accessibilityIdentifier("companion.quit")
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .foregroundStyle(.white)
        .background {
            if reduceTransparency {
                Color(red: 0.08, green: 0.08, blue: 0.085)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.025, green: 0.025, blue: 0.03),
                            Color(red: 0.075, green: 0.075, blue: 0.088)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [.white.opacity(0.045), .clear],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: 220
                    )
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(reduced ? nil : .easeOut(duration: 0.16), value: showAll)
    }

    private func taskRows(for state: DesktopCompanionState) -> some View {
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
            .background(.white.opacity(hovered ? 0.11 : 0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(
                urgent ? Color.orange.opacity(0.38) : .white.opacity(hovered ? 0.16 : 0.08), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.985))
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
            .padding(.horizontal, 16).frame(height: 38)
            .background(.white.opacity(hovered ? 1.0 : 0.93), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.98))
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
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.orange.opacity(0.32), lineWidth: 0.5))
    }
}
