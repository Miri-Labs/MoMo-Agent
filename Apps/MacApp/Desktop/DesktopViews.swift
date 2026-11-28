import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import MoMoAgentClient
import MoMoContracts

struct DesktopRoot: View {
    @Bindable var model: DesktopModel
    @State private var sidebarVisible = true
    @State private var sidebarExpandedWidth: CGFloat = 220
    @State private var chatDetailOpen = false
    @State private var memoryDetailOpen = false
    @State private var sourcesDetailOpen = false
    @State private var inspectorWidth: CGFloat = 360
    @State private var sourcesResetToken: UInt64 = 0
    @State private var composerFocusToken: UInt64 = 0
    @State private var recordingCitation: RecordingCitation?
    @State private var previewingMemoryNote: ContextMemory?
    @Environment(\.openWindow) private var openWindow

    private var activeDetailOpen: Bool {
        switch model.selection {
        case "memory": memoryDetailOpen
        case "sources": sourcesDetailOpen
        default: chatDetailOpen
        }
    }

    private var activeDetailBinding: Binding<Bool> {
        switch model.selection {
        case "memory": $memoryDetailOpen
        case "sources": $sourcesDetailOpen
        default: $chatDetailOpen
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DesktopTopChromeBar(
                model: model,
                sidebarVisible: $sidebarVisible,
                sidebarExpandedWidth: sidebarExpandedWidth,
                chatDetailOpen: $chatDetailOpen,
                activeDetailOpen: activeDetailBinding
            )

            HStack(spacing: 0) {
                DesktopSidebarRail(
                    selection: model.selection,
                    busy: model.taskStore?.hasActiveTask == true,
                    memoryCount: model.vaultSnapshot.activeMemories.count,
                    sidebarVisible: sidebarVisible,
                    onSelect: { target in
                        if target == "sources" && model.selection == "sources" {
                            sourcesResetToken &+= 1
                        } else {
                            model.selection = target
                        }
                    },
                    onOpenSettings: {
                        openWindow(id: MoMoAgentMacApp.settingsID)
                    }
                )
                .frame(width: sidebarVisible ? sidebarExpandedWidth : 60)
                .overlay(alignment: .trailing) {
                    DesktopSidebarResizeHandle(
                        sidebarVisible: $sidebarVisible,
                        expandedWidth: $sidebarExpandedWidth
                    )
                }

                // Floating white workspace card framed against the outer gray shell (#F2F2F4 / #0D0D0F).
                VStack(spacing: 0) {
                    if let failure = model.failure {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12.5))
                                .foregroundStyle(MoMoPalette.failure)
                            Text(failure)
                                .font(.system(size: 12.5))
                                .lineLimit(2)
                            Spacer()
                            Button("关闭") { model.failure = nil }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(MoMoPalette.failureBackground)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(MoMoPalette.borderSubtle).frame(height: 0.5)
                        }
                        .accessibilityIdentifier("desktop.failure")
                    }

                    Group {
                        switch model.selection {
                        case "memory":
                            DesktopMemory(
                                model: model,
                                isActive: true,
                                detailOpen: $memoryDetailOpen,
                                inspectorWidth: $inspectorWidth
                            )
                        case "sources":
                            DesktopSources(
                                model: model,
                                isActive: true,
                                resetToken: sourcesResetToken,
                                detailOpen: $sourcesDetailOpen,
                                inspectorWidth: $inspectorWidth
                            )
                        default:
                            DesktopChat(
                                model: model,
                                isActive: true,
                                composerFocusToken: composerFocusToken,
                                detailOpen: $chatDetailOpen,
                                inspectorWidth: $inspectorWidth
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .sandInsetStage(cornerRadius: 16, fill: MoMoPalette.pane)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
        .background(MoMoPalette.sidebar)
        .background(DesktopWindowChrome())
        .ignoresSafeArea(.container)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "momoagent" else { return .systemAction }
            if DreamMemoryLinkResolver.isMemoryURL(url) {
                if let matched = DreamMemoryLinkResolver.resolve(url: url, in: model.vaultSnapshot.activeMemories) {
                    previewingMemoryNote = matched
                } else {
                    Task {
                        await model.loadContext()
                        if let matched = DreamMemoryLinkResolver.resolve(url: url, in: model.vaultSnapshot.activeMemories) {
                            previewingMemoryNote = matched
                        } else {
                            model.selection = "memory"
                        }
                    }
                }
                return .handled
            }
            if let citation = RecordingCitation(url: url) { recordingCitation = citation }
            else { model.failure = String(localized: "这条录音来源不可用。") }
            return .handled
        })
        .sheet(item: $recordingCitation) { citation in
            DesktopRecordingCitation(model: model, citation: citation)
        }
        .sheet(item: $previewingMemoryNote) { note in
            MemoryNotePreviewSheet(
                memory: note,
                allMemories: model.vaultSnapshot.activeMemories,
                onOpenFullNotebook: { model.selection = "memory" }
            )
        }
        .alert(
            model.taskStore?.activeProviderNotice?.title ?? "",
            isPresented: Binding(
                get: { model.taskStore?.activeProviderNotice != nil },
                set: { if !$0 { model.taskStore?.dismissProviderNotice() } }
            ),
            presenting: model.taskStore?.activeProviderNotice
        ) { notice in
            Button("更换模型服务") {
                model.taskStore?.dismissProviderNotice(notice.id)
                model.managingModel = true
                openWindow(id: MoMoAgentMacApp.settingsID)
            }
            Button("知道了", role: .cancel) {
                model.taskStore?.dismissProviderNotice(notice.id)
            }
        } message: { notice in
            Text(verbatim: notice.message)
        }
    }
}

/// Draggable resize handle with Grok Bot 10pt collapse hysteresis (collapses < 168pt, expands > 178pt).
private struct DesktopSidebarResizeHandle: View {
    @Binding var sidebarVisible: Bool
    @Binding var expandedWidth: CGFloat
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragStartWidth ?? (sidebarVisible ? expandedWidth : 76)
                        if dragStartWidth == nil { dragStartWidth = base }
                        let proposed = base + value.translation.width
                        if sidebarVisible && proposed < 168 {
                            sidebarVisible = false
                        } else if !sidebarVisible && proposed > 178 {
                            sidebarVisible = true
                            expandedWidth = min(284, max(204, proposed))
                        } else if sidebarVisible {
                            expandedWidth = min(284, max(204, proposed))
                        }
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            .accessibilityHidden(true)
    }
}

/// Unified 44pt top gray chrome bar housing traffic lights space, sidebar toggle aligned to the white card's left edge,
/// and right-aligned toolbar controls (chat mode capsule, tasks toggle, and right detail sidebar toggle).
private struct DesktopTopChromeBar: View {
    @Bindable var model: DesktopModel
    @Binding var sidebarVisible: Bool
    let sidebarExpandedWidth: CGFloat
    @Binding var chatDetailOpen: Bool
    @Binding var activeDetailOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        ZStack {
            DesktopWindowDragRegion()

            HStack(spacing: 0) {
                // Reserve traffic-light space so the sidebar toggle aligns flush with the floating white card's left edge.
                Color.clear
                    .frame(width: sidebarVisible ? max(80, sidebarExpandedWidth - 6) : 76)
                    .allowsHitTesting(false)

                DesktopSidebarToggleButton(sidebarVisible: sidebarVisible) {
                    withAnimation(reducedMotion ? nil : .spring(duration: 0.3, bounce: 0.1)) {
                        sidebarVisible.toggle()
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    if model.selection == "chat", let store = model.taskStore {
                        DesktopChatModeCapsule(store: store)
                        DesktopActiveTasksBadgeButton(store: store, showingActiveTasks: $chatDetailOpen)
                    }

                    DesktopRightPanelToggleButton(isOpen: activeDetailOpen) {
                        withAnimation(reducedMotion ? nil : DesktopRightInspectorContainer<EmptyView>.toggleAnimation) {
                            activeDetailOpen.toggle()
                        }
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .frame(height: 44)
    }
}

/// Codex-aligned collapsible right inspector (`E.m9` spring 0.5s bounce 0.1, fixed inner frame so content never squishes during reveal, leading 0.5pt border + subtle elevation shadow, 320–520pt drag resize with 160pt collapse hysteresis).
struct DesktopRightInspectorContainer<Content: View>: View {
    static var toggleAnimation: Animation { .spring(duration: 0.5, bounce: 0.1) }
    private static var minWidth: CGFloat { 320 }
    private static var maxWidth: CGFloat { 520 }
    private static var collapseThreshold: CGFloat { 160 } // Codex B7: 0.5 * 320

    @Binding var isOpen: Bool
    @Binding var width: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var dragStartWidth: CGFloat?
    @State private var dragCollapsePreview = false
    @State private var handleHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        let clampedWidth = min(Self.maxWidth, max(Self.minWidth, width))
        let visibleWidth: CGFloat = isOpen ? clampedWidth : 0

        ZStack(alignment: .leading) {
            content()
                .frame(width: clampedWidth)
                .frame(maxHeight: .infinity)
                .background(MoMoPalette.pane)
        }
        .frame(width: visibleWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(isOpen)
        .accessibilityHidden(!isOpen)
        .overlay(alignment: .leading) {
            if isOpen {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 1)
                        .shadow(
                            color: Color.black.opacity(colorScheme == .dark ? 0.30 : 0.08),
                            radius: 8,
                            x: -4,
                            y: 0
                        )
                        .allowsHitTesting(false)

                    Rectangle()
                        .fill(handleHovered || dragStartWidth != nil ? MoMoPalette.borderFocus : MoMoPalette.borderSubtle)
                        .frame(width: handleHovered || dragStartWidth != nil ? 1.0 : 0.5)
                        .allowsHitTesting(false)

                    Color.clear
                        .frame(width: 7)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            handleHovered = inside
                            if inside { NSCursor.resizeLeftRight.push() }
                            else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                                .onChanged { value in
                                    let base = dragStartWidth ?? clampedWidth
                                    if dragStartWidth == nil { dragStartWidth = base }
                                    let proposed = base - value.translation.width
                                    if proposed < Self.collapseThreshold {
                                        dragCollapsePreview = true
                                    } else {
                                        dragCollapsePreview = false
                                        width = min(Self.maxWidth, max(Self.minWidth, proposed))
                                    }
                                }
                                .onEnded { _ in
                                    let shouldCollapse = dragCollapsePreview
                                    dragStartWidth = nil
                                    dragCollapsePreview = false
                                    if shouldCollapse {
                                        withAnimation(reducedMotion ? nil : Self.toggleAnimation) {
                                            isOpen = false
                                        }
                                    }
                                }
                        )
                }
                .accessibilityHidden(true)
            }
        }
        .animation(dragStartWidth != nil || reducedMotion ? nil : Self.toggleAnimation, value: isOpen)
    }
}

/// Outer-shell navigation rail resting directly on the gray window base.
private struct DesktopSidebarRail: View {
    let selection: String
    let busy: Bool
    let memoryCount: Int
    let sidebarVisible: Bool
    let onSelect: (String) -> Void
    let onOpenSettings: () -> Void
    @State private var commandHeld = false
    @State private var flagsMonitor: Any?

    var body: some View {
        VStack(alignment: sidebarVisible ? .leading : .center, spacing: 0) {
            if sidebarVisible {
                HStack(spacing: 9.5) {
                    PhoneBrandIcon(size: 26)
                    PhoneBrandWordmark(size: 17.5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .background(DesktopWindowDragRegion())

                VStack(spacing: 3) {
                    DesktopSidebarNavButton(
                        title: "首页",
                        icon: "house",
                        isSelected: selection == "chat",
                        badgeText: nil,
                        isWorking: busy,
                        keycap: commandHeld ? "⌘1" : nil,
                        accessibilityID: "desktop.destination.chat"
                    ) {
                        onSelect("chat")
                    }
                    DesktopSidebarNavButton(
                        title: "记忆",
                        icon: "book.closed",
                        isSelected: selection == "memory",
                        badgeText: memoryCount > 0 ? "\(memoryCount)" : nil,
                        isWorking: false,
                        keycap: commandHeld ? "⌘2" : nil,
                        accessibilityID: "desktop.destination.memory"
                    ) {
                        onSelect("memory")
                    }
                    DesktopSidebarNavButton(
                        title: "转录",
                        icon: "waveform",
                        isSelected: selection == "sources",
                        badgeText: nil,
                        isWorking: false,
                        keycap: commandHeld ? "⌘3" : nil,
                        accessibilityID: "desktop.destination.sources"
                    ) {
                        onSelect("sources")
                    }
                }
                .padding(.horizontal, 10)

                Spacer(minLength: 16)
                    .background(DesktopWindowDragRegion())

                DesktopSidebarNavButton(
                    title: "设置",
                    icon: "gearshape",
                    isSelected: false,
                    badgeText: nil,
                    isWorking: false,
                    keycap: commandHeld ? "⌘," : nil,
                    accessibilityID: nil,
                    action: onOpenSettings
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            } else {
                PhoneBrandIcon(size: 24)
                    .padding(.top, 4)
                    .padding(.bottom, 12)

                VStack(spacing: 5) {
                    DesktopSidebarIconButton(title: "首页", helpText: "首页（⌘1）", icon: "house", isSelected: selection == "chat", accessibilityID: "desktop.destination.chat") {
                        onSelect("chat")
                    }
                    DesktopSidebarIconButton(title: "记忆", helpText: "记忆（⌘2）", icon: "book.closed", isSelected: selection == "memory", accessibilityID: "desktop.destination.memory") {
                        onSelect("memory")
                    }
                    DesktopSidebarIconButton(title: "转录", helpText: "转录（⌘3）", icon: "waveform", isSelected: selection == "sources", accessibilityID: "desktop.destination.sources") {
                        onSelect("sources")
                    }
                }

                Spacer(minLength: 16)
                    .background(DesktopWindowDragRegion())

                DesktopSidebarIconButton(title: "设置", helpText: "设置（⌘,）", icon: "gearshape", isSelected: false, accessibilityID: nil, action: onOpenSettings)
                    .padding(.bottom, 14)
            }
        }
        .onAppear {
            if flagsMonitor == nil {
                flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let onlyCmd = event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
                    if commandHeld != onlyCmd {
                        commandHeld = onlyCmd
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
        }
    }
}

/// Native zero-WebKit MoMo avatar with Grok Bot `--sand-status-dot-ring` cutout badge.
struct SandNativeAvatarBadge: View {
    var size: CGFloat = 26
    var online: Bool = true
    var busy: Bool = false
    var ringBackground: Color = MoMoPalette.canvas

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(MoMoPalette.ink.opacity(0.07))
                Image("MoMoStill")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(MoMoPalette.ink)
                    .frame(width: size * 0.72, height: size * 0.72)
            }
            .frame(width: size, height: size)

            Circle()
                .fill(busy ? Color(red: 0.12, green: 0.53, blue: 0.99) : (online ? MoMoPalette.ink.opacity(0.75) : MoMoPalette.muted.opacity(0.38)))
                .frame(width: 7, height: 7)
                .overlay {
                    Circle().stroke(ringBackground, lineWidth: 1.8)
                }
                .offset(x: 1.5, y: 1.5)
        }
        .accessibilityHidden(true)
    }
}

private struct DesktopSidebarQuickAskButton: View {
    let keycap: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MoMoPalette.ink)
                Text("向 MoMo 提问")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(MoMoPalette.ink)
                Spacer(minLength: 4)
                if let keycap {
                    SandKeyCapBadge(text: keycap)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 33)
            .momoElevatedCard(cornerRadius: 999, isFocused: hovered, shadowStrength: hovered ? 0.95 : 0.55)
            .contentShape(Capsule())
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.98))
        .onHover { hovered = $0 }
        .keyboardShortcut("n", modifiers: [.command])
        .help("聚焦输入框向 MoMo 提问（⌘N）")
    }
}

private struct DesktopSidebarQuickAskCompactButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(MoMoPalette.ink)
                .frame(width: 34, height: 34)
                .momoElevatedCard(cornerRadius: 999, isFocused: hovered, shadowStrength: 0.6)
                .contentShape(Circle())
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.94))
        .onHover { hovered = $0 }
        .keyboardShortcut("n", modifiers: [.command])
        .help("向 MoMo 提问（⌘N）")
    }
}

private struct SandKeyCapBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(MoMoPalette.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(MoMoPalette.ink.opacity(0.055), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(MoMoPalette.borderSubtle, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

private struct DesktopSidebarAgentPod: View {
    let online: Bool
    let busy: Bool
    let keycap: String?
    let onSelectChat: () -> Void
    let onOpenSettings: () -> Void
    @State private var podHovered = false
    @State private var gearHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelectChat) {
                HStack(spacing: 9) {
                    SandNativeAvatarBadge(size: 28, online: online, busy: busy, ringBackground: MoMoPalette.sidebar)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("MoMo")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(MoMoPalette.ink)
                        Text(online ? (busy ? "正在处理任务…" : "在线就绪") : "尚未运行")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(MoMoPalette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    podHovered ? MoMoPalette.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { podHovered = $0 }

            Button(action: onOpenSettings) {
                HStack(spacing: 4) {
                    if let keycap {
                        SandKeyCapBadge(text: keycap)
                    }
                    Image(systemName: "gearshape")
                        .font(.system(size: 13.5, weight: .regular))
                        .foregroundStyle(gearHovered ? MoMoPalette.ink : MoMoPalette.muted)
                        .frame(width: 28, height: 28)
                        .background(
                            gearHovered ? MoMoPalette.hoverFill : Color.clear,
                            in: Circle()
                        )
                        .contentShape(Circle())
                }
            }
            .buttonStyle(MoMoPressableButtonStyle(scale: 0.94))
            .onHover { gearHovered = $0 }
            .help("设置（⌘,）")
            .accessibilityLabel("设置")
        }
    }
}

/// Clean minimalist Codex-style split-pane icon (rounded rect + single vertical divider, no inner dashes).
private struct CodexSidebarPaneShape: Shape {
    let side: CodexSidebarPaneIcon.Side

    func path(in rect: CGRect) -> Path {
        let box = CGRect(x: 1.5, y: 2.5, width: rect.width - 3, height: rect.height - 5)
        var path = Path(roundedRect: box, cornerRadius: 3.0, style: .continuous)
        let dividerX = side == .left ? box.minX + box.width * 0.34 : box.maxX - box.width * 0.34
        path.move(to: CGPoint(x: dividerX, y: box.minY + 0.5))
        path.addLine(to: CGPoint(x: dividerX, y: box.maxY - 0.5))
        return path
    }
}

private struct CodexSidebarPaneIcon: View {
    enum Side { case left, right }
    let side: Side

    var body: some View {
        CodexSidebarPaneShape(side: side)
            .stroke(style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 17)
            .accessibilityHidden(true)
    }
}

private struct DesktopSidebarToggleButton: View {
    let sidebarVisible: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            CodexSidebarPaneIcon(side: .left)
                .foregroundStyle(hovered ? MoMoPalette.ink : MoMoPalette.ink.opacity(0.62))
                .frame(width: 30, height: 30)
                .background(
                    hovered ? MoMoPalette.hoverFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.95))
        .onHover { hovered = $0 }
        .help(sidebarVisible ? "收起侧栏（⌃⌘S）" : "展开侧栏（⌃⌘S）")
        .accessibilityLabel(sidebarVisible ? "收起侧栏" : "显示侧栏")
        .accessibilityIdentifier("desktop.sidebarToggle")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }
}

private struct DesktopRightPanelToggleButton: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            CodexSidebarPaneIcon(side: .right)
                .foregroundStyle(isOpen || hovered ? MoMoPalette.ink : MoMoPalette.ink.opacity(0.62))
                .frame(width: 30, height: 30)
                .background(
                    isOpen ? MoMoPalette.activeFill : (hovered ? MoMoPalette.hoverFill : Color.clear),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.95))
        .onHover { hovered = $0 }
        .help(isOpen ? "收起右侧详情栏" : "展开右侧详情栏")
        .accessibilityLabel(isOpen ? "收起右侧详情栏" : "展开右侧详情栏")
        .accessibilityIdentifier("desktop.rightPanelToggle")
    }
}

private struct DesktopSidebarNavButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let badgeText: String?
    let isWorking: Bool
    let keycap: String?
    let accessibilityID: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let btn = Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? MoMoPalette.ink : MoMoPalette.muted)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 14.5, weight: isSelected ? .medium : .regular))
                    .tracking(-0.06)
                    .foregroundStyle(isSelected ? MoMoPalette.ink : MoMoPalette.ink.opacity(0.84))
                Spacer(minLength: 4)
                if let keycap {
                    SandKeyCapBadge(text: keycap)
                } else if isWorking {
                    SandWorkingDots()
                } else if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 11.5, weight: .regular).monospacedDigit())
                        .foregroundStyle(MoMoPalette.muted)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 1.5)
                        .background(MoMoPalette.ink.opacity(0.055), in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .padding(.horizontal, 10)
            .background(
                isSelected ? MoMoPalette.activeFill : (hovered ? MoMoPalette.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.985))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let accessibilityID {
            btn.accessibilityIdentifier(accessibilityID)
        } else {
            btn
        }
    }
}

private struct DesktopSidebarIconButton: View {
    let title: String
    let helpText: String
    let icon: String
    let isSelected: Bool
    let accessibilityID: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let btn = Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected || hovered ? MoMoPalette.ink : MoMoPalette.muted)
                .frame(width: 36, height: 34)
                .background(
                    isSelected ? MoMoPalette.activeFill : (hovered ? MoMoPalette.hoverFill : Color.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.94))
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(LocalizedStringKey(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])

        if let accessibilityID {
            btn.accessibilityIdentifier(accessibilityID)
        } else {
            btn
        }
    }
}

/// Grok Bot `sand-kit-working-badge` lightweight 3-dot pulse without WebKit overhead.
struct SandWorkingDots: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(MoMoPalette.ink.opacity(pulsing ? 0.85 : 0.25))
                    .frame(width: 3.5, height: 3.5)
                    .animation(
                        .easeInOut(duration: 0.65).repeatForever(autoreverses: true).delay(Double(idx) * 0.16),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
        .accessibilityHidden(true)
    }
}

struct DesktopDevices: View {
    private enum RowLayout {
        static let symbolColumn: CGFloat = 22
        static let labelSpacing: CGFloat = 9
    }

    @Bindable var model: DesktopModel
    @State private var revoking: AccessStatus.Device?
    @State private var showingPairing = false
    @Binding var showingMethod: Bool
    @State private var detailsExpanded = false

    var body: some View {
        Form {
            if showingMethod {
                Section {
                    DesktopConnectionSetup(model: model, inSettings: true, onSaved: { showingMethod = false })
                }
            } else {
                if model.status == nil {
                    Section {
                        LabeledContent {
                            Button("准备") { Task { await model.prepare() } }
                                .disabled(model.busy != nil).accessibilityIdentifier("desktop.prepare")
                        } label: { Text("准备此 Mac 后可配对手机") }
                    }
                    Section { connectionDetails }
                } else {
                    devices
                    network
                }
                if let busy = model.busy { ProgressView(busy).controlSize(.small) }
                if let failure = model.failure {
                    Text(failure).font(.callout).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPairing, onDismiss: { model.isPairingDevice = false }) {
            DesktopPairingSheet(model: model, onFinish: { showingPairing = false })
        }
        .onDisappear { model.isPairingDevice = false }
        .confirmationDialog("移除这台设备？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            if let revoking { Button("移除设备", role: .destructive) { Task { await model.control("devices/revoke", body: ["id": revoking.id]) }; self.revoking = nil } }
        } message: { Text("它将无法访问这台电脑，已有任务会继续。") }
    }

    private var pairPhone: some View {
        Button {
            model.isPairingDevice = true
            Task {
                if model.status?.invitation == nil { _ = await model.inviteForPairing() }
                showingPairing = true
            }
        } label: {
            HStack(spacing: RowLayout.labelSpacing) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: RowLayout.symbolColumn)
                    .accessibilityHidden(true)
                Text("配对手机").fontWeight(.medium)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.accentColor)
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy != nil).accessibilityIdentifier("desktop.addDevice")
    }

    private var devices: some View {
        let paired = model.status?.devices.filter { $0.state == "approved" } ?? []
        return Section {
            ForEach(paired) { device in
                HStack(spacing: RowLayout.labelSpacing) {
                    Image(systemName: "iphone").font(.system(size: 19, weight: .regular))
                        .frame(width: RowLayout.symbolColumn).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: device.name).font(.body.weight(.medium))
                        if let seen = device.lastSeen, seen > 0 {
                            HStack(spacing: 4) {
                                Text("上次联系")
                                Text(Date(timeIntervalSince1970: seen), format: .relative(presentation: .named))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 10)
                    Menu {
                        Button("移除设备", role: .destructive) { revoking = device }
                    } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.medium))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(Text("更多") + Text(verbatim: " · " + device.name))
                    .disabled(model.busy != nil)
                    .accessibilityIdentifier("desktop.deviceActions")
                }
                .padding(.vertical, 1)
            }
            pairPhone
        } header: {
            Text(paired.isEmpty ? "尚未配对手机" : "已配对设备")
        }
    }

    private var connectionDetails: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let url = model.status?.tunnel.endpoint {
                    LabeledContent("当前地址") {
                        Text(verbatim: url).font(.callout.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                DesktopNetworkProxy(model: model)
            }.padding(.top, 12).padding(.leading, 5)
        } label: {
            Text("连接详情")
        }
        .accessibilityIdentifier("desktop.connectionDetails")
    }

    private var network: some View {
        Section("这台 Mac") {
            LabeledContent {
                HStack(spacing: 8) {
                    Text(tunnelLabel).foregroundStyle(.secondary)
                    Toggle("远程访问", isOn: Binding(get: { model.status?.tunnel.state != "stopped" }, set: { enabled in
                        Task { await model.control(enabled ? "tunnel/start" : "tunnel/stop") }
                    }))
                    .labelsHidden().toggleStyle(.switch)
                    .accessibilityHint(tunnelLabel)
                    .disabled(model.busy != nil).accessibilityIdentifier("desktop.remoteAccess")
                }
            } label: { Text("远程访问") }
            Button { showingMethod = true } label: {
                HStack {
                    Text("连接方式")
                    Spacer()
                    Text(["tailscale", "embedded"].contains(model.status?.tunnel.mode ?? "") ? "Tailscale 私网" : model.status?.tunnel.mode == "external" ? "自建服务器" : model.status?.tunnel.mode == "relay" ? "加密中继" : "待选择").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(.secondary).accessibilityHidden(true)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(model.busy != nil).accessibilityIdentifier("desktop.connectionMethod")
            connectionDetails
            if let error = model.status?.tunnel.error {
                Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure).textSelection(.enabled)
            }
        }
    }

    private var tunnelLabel: String {
        switch model.status?.tunnel.state {
        case "connected": String(localized: "可用")
        case "starting": String(localized: "准备中")
        case "reconnecting": String(localized: "恢复中")
        case "failed", "needs_setup": String(localized: "需要设置")
        default: String(localized: "已关闭")
        }
    }
}

struct PairingQRCode: View {
    let payload: String
    @State private var image: NSImage?
    var body: some View {
        Group { if let image { Image(nsImage: image).interpolation(.none).resizable().scaledToFit() } else { ProgressView() } }
            .accessibilityLabel("手机配对二维码")
            .task(id: payload) {
                let filter = CIFilter.qrCodeGenerator(); filter.message = Data(payload.utf8); filter.correctionLevel = "M"
                guard let output = filter.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return }
                image = NSImage(cgImage: cg, size: output.extent.size)
            }
    }
}

struct DesktopChat: View {
    @Environment(\.openWindow) private var openWindow
    private let headerOverlap: CGFloat = 12
    @Bindable var model: DesktopModel
    var isActive: Bool = true
    var composerFocusToken: UInt64 = 0
    @Binding var detailOpen: Bool
    @Binding var inspectorWidth: CGFloat
    @State private var composeRevision = 0
    @State private var previewAttachment: AgentAttachment?
    @State private var dismissedBriefingCardIDs: Set<String> = DreamDismissedCardsStore.load()
    @State private var showingBriefingDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    private var briefingDocument: DreamBriefingDocument? {
        model.vaultSnapshot.briefingDocument
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let store = model.taskStore {
                    let isEmpty = store.isEmpty

                    // Iconic centered MoMo live mascot header with independent status dot & hover card.
                    VStack(spacing: isEmpty ? 18 : 6) {
                        ZStack(alignment: .bottomTrailing) {
                            PersonalAgentSlot(
                                size: isEmpty ? 136 : 54,
                                active: isActive && (isEmpty || store.hasActiveTask),
                                playful: isEmpty,
                                expression: store.hasActiveTask ? .thinking : .present
                            )
                            DesktopMascotStatusAnchor(
                                model: model,
                                online: model.isAgentOnline,
                                busy: store.hasActiveTask,
                                isLarge: isEmpty,
                                onOpenSettings: {
                                    model.managingConnection = true
                                    openWindow(id: MoMoAgentMacApp.settingsID)
                                }
                            )
                            .offset(x: isEmpty ? -18 : -2, y: isEmpty ? -22 : -4)
                        }
                        .zIndex(20)
                        PhoneBrandWordmark(.momo, size: isEmpty ? 22 : 12)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: isEmpty ? .infinity : nil)
                    .padding(.top, isEmpty ? 0 : 18)
                    .padding(.bottom, isEmpty ? 0 : 8)
                    .zIndex(5)

                    if !isEmpty {
                        // Isolated transcript host: never re-evaluates or rebuilds 400+ message snapshot when typing in draft!
                        DesktopChatTranscriptStage(
                            store: store,
                            readingPosition: model.readingPosition,
                            composeRevision: composeRevision,
                            headerOverlap: headerOverlap,
                            isChatVisible: isActive && !showingBriefingDetail && previewAttachment == nil,
                            isChatSelected: isActive,
                            onReadingPosition: model.rememberReadingPosition,
                            onPreviewAttachment: { previewAttachment = $0 },
                            onNavigateSources: {
                                model.failure = nil
                                model.selection = "sources"
                            },
                            onError: { model.failure = $0 }
                        )
                        .padding(.top, -headerOverlap)
                    }

                    DesktopHomeSuggestionsHost(
                        store: store,
                        briefingDocument: briefingDocument,
                        compact: !isEmpty,
                        dismissedBriefingCardIDs: $dismissedBriefingCardIDs,
                        onSent: { composeRevision += 1 },
                        onOpenBriefing: { showingBriefingDetail = true },
                        onOpenNotebook: { model.selection = "memory" },
                        onError: { model.failure = $0 }
                    )
                    .frame(maxWidth: 724)

                    RemoteTaskControlsView(store: store, returnDesktop: {
                        do { try model.desktopHost?.returnControl() }
                        catch { model.failure = error.localizedDescription }
                    })
                    .frame(maxWidth: 724)

                    RemoteTaskRecoveryView(store: store)
                        .frame(maxWidth: 724)

                    if let failure = store.interactionFailure {
                        Text(failure)
                            .font(.system(size: 12))
                            .foregroundStyle(MoMoPalette.failure)
                            .padding(.bottom, 4)
                    }

                    DesktopComposerHost(
                        store: store,
                        focusRequestToken: composerFocusToken,
                        onSent: { composeRevision += 1 },
                        onPreviewAttachment: { previewAttachment = $0 },
                        onError: { model.failure = $0 }
                    )
                    .frame(maxWidth: 724)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                    .padding(.top, 8)
                } else {
                    Spacer()
                    ZStack(alignment: .bottomTrailing) {
                        PersonalAgentSlot(size: 136, active: false, expression: .concerned)
                        DesktopMascotStatusAnchor(
                            model: model,
                            online: false,
                            busy: false,
                            isLarge: true,
                            onOpenSettings: {
                                model.managingConnection = true
                                openWindow(id: MoMoAgentMacApp.settingsID)
                            }
                        )
                        .offset(x: -18, y: -22)
                    }
                    .zIndex(20)
                    PhoneBrandWordmark(.momo, size: 22).padding(.top, 10)
                    Text("MoMo 暂时没有连接上")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(MoMoPalette.muted)
                        .padding(.top, 4)
                    Button("检查连接") {
                        model.managingConnection = true
                        openWindow(id: MoMoAgentMacApp.settingsID)
                    }
                    .buttonStyle(DesktopSetupButton(minimumHeight: 42, fontSize: 13.5))
                    .frame(width: 200)
                    .padding(.top, 14)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MoMoPalette.pane)

            DesktopRightInspectorContainer(isOpen: $detailOpen, width: $inspectorWidth) {
                VStack(spacing: 0) {
                    let tasksSnap = AgentActiveTasksSnapshot(store: model.taskStore)
                    HStack(spacing: 8) {
                        Text("任务")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MoMoPalette.ink)
                        Spacer(minLength: 8)
                        if tasksSnap.count > 0 {
                            Text("\(tasksSnap.count) 项进行中")
                                .font(.system(size: 11))
                                .foregroundStyle(MoMoPalette.muted)
                        }
                        Button {
                            withAnimation(reduced ? nil : DesktopRightInspectorContainer<EmptyView>.toggleAnimation) {
                                detailOpen = false
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(MoMoPalette.muted)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("收起任务栏")
                        .accessibilityLabel("收起任务栏")
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .frame(height: 44)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(MoMoPalette.borderSubtle).frame(height: 0.5)
                    }

                    AgentActiveTasksSheet(store: model.taskStore, isPopover: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MoMoPalette.pane)
        .task {
            if model.memories.isEmpty {
                await model.loadContextIfStale(maxAge: 15)
            }
        }
        .sheet(item: $previewAttachment) { ClientAttachmentPreview(attachment: $0) }
        .sheet(isPresented: $showingBriefingDetail) {
            if let doc = briefingDocument {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(doc.headline).phoneText(.heading)
                        Spacer()
                        Button("完成") { showingBriefingDetail = false }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(MoMoPalette.muted)
                    }
                    Rectangle().fill(MoMoPalette.borderSubtle).frame(height: 0.5)
                    ScrollView {
                        MarkdownReadingView(markdown: MemoryCardDigest.cleanNotebookMarkdownForDetail(doc.rawMarkdown), accessibilityID: "desktop.dreamBriefingMarkdown", handwriting: true)
                            .equatable()
                            .memoryNotebookPage()
                    }
                }
                .padding(24)
                .frame(minWidth: 520, minHeight: 420)
                .background(MoMoPalette.paper)
            }
        }
        .animation(reduced ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: model.taskStore?.isEmpty)
    }
}

/// Independent green/red status dot placed at the bottom-right of the Chat MoMo avatar.
/// Hovering (or clicking) the dot reveals a compact non-wrapping status popover; when offline, includes a direct link to Settings.
private struct DesktopMascotStatusAnchor: View {
    let model: DesktopModel
    let online: Bool
    let busy: Bool
    let isLarge: Bool
    let onOpenSettings: () -> Void
    @State private var dotHovered = false
    @State private var popoverHovered = false
    @State private var showingPopover = false
    @State private var closeTask: Task<Void, Never>?

    private var dotColor: Color {
        online
            ? Color(.sRGB, red: 40.0 / 255, green: 200.0 / 255, blue: 64.0 / 255)
            : Color(.sRGB, red: 255.0 / 255, green: 69.0 / 255, blue: 58.0 / 255)
    }

    private var statusTitle: String {
        if !online { return "MoMo 尚未运行" }
        return busy ? "MoMo 正在思考…" : "MoMo 正在运行"
    }

    private var moodText: String {
        if !online { return "本地引擎休眠中，可前往设置检查连接" }
        if busy { return "正在认真处理你的任务，稍等片刻 ✦" }
        return "耳朵竖着，等你随时喊我 ✦"
    }

    private func scheduleCloseIfNeeded() {
        closeTask?.cancel()
        guard !dotHovered && !popoverHovered else { return }
        closeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled && !dotHovered && !popoverHovered {
                showingPopover = false
            }
        }
    }

    var body: some View {
        let dotSize: CGFloat = isLarge ? 16 : 11
        let ringWidth: CGFloat = isLarge ? 3 : 2.2

        Button {
            closeTask?.cancel()
            showingPopover.toggle()
        } label: {
            Circle()
                .fill(dotColor)
                .frame(width: dotSize, height: dotSize)
                .overlay {
                    Circle().stroke(MoMoPalette.pane, lineWidth: ringWidth)
                }
                .shadow(color: Color.black.opacity(0.14), radius: 2, x: 0, y: 1)
                .scaleEffect(dotHovered ? 1.15 : 1.0)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.14)) {
                dotHovered = inside
            }
            if inside {
                closeTask?.cancel()
                showingPopover = true
            } else {
                scheduleCloseIfNeeded()
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MoMoPalette.ink)
                    if !online {
                        Spacer(minLength: 10)
                        Button {
                            showingPopover = false
                            onOpenSettings()
                        } label: {
                            HStack(spacing: 2) {
                                Text("前往设置")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("打开设置检查连接")
                    }
                }
                Text(moodText)
                    .font(.system(size: 12))
                    .foregroundStyle(MoMoPalette.ink.opacity(0.84))
                    .fixedSize(horizontal: true, vertical: false)

                Rectangle()
                    .fill(MoMoPalette.borderSubtle)
                    .frame(height: 0.5)
                    .padding(.top, 2)

                HStack(spacing: 14) {
                    let todayKey = DesktopTranscriptSnapshot.dayKey(for: Date())
                    let todayCount = model.transcriptSnapshot.windowsByDayKey[todayKey]?.count ?? 0
                    let memoryCount = model.vaultSnapshot.activeMemories.count
                    Text("今日转录 \(todayCount) 段")
                    Text("记忆 \(memoryCount) 篇")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(MoMoPalette.muted)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(MoMoPalette.paper)
            .onHover { inside in
                popoverHovered = inside
                if inside {
                    closeTask?.cancel()
                } else {
                    scheduleCloseIfNeeded()
                }
            }
        }
        .onDisappear { closeTask?.cancel() }
        .accessibilityLabel(statusTitle)
    }
}

/// Strictly isolated transcript stage so typing in `store.draft` NEVER rebuilds `ChatRenderSnapshot`.
private struct DesktopChatTranscriptStage: View {
    let store: RemoteTaskStore
    let readingPosition: ChatReadingPosition?
    let composeRevision: Int
    let headerOverlap: CGFloat
    let isChatVisible: Bool
    let isChatSelected: Bool
    let onReadingPosition: (ChatReadingPosition) -> Void
    let onPreviewAttachment: (AgentAttachment) -> Void
    let onNavigateSources: () -> Void
    let onError: (String) -> Void

    var body: some View {
        let snapshot = ChatRenderSnapshot(store: store, readingPosition: readingPosition)
        ChatRendererView(
            snapshot: snapshot,
            scrollToBottomRequest: composeRevision,
            isChatVisible: isChatVisible,
            isChatSelected: isChatSelected,
            headerInset: headerOverlap,
            onReadingPosition: onReadingPosition,
            onAttachment: { id in
                if let att = store.attachment(id: id) {
                    onPreviewAttachment(att)
                }
            },
            onRetryMessage: { id in
                do {
                    if try store.reselectRecording(id: id) {
                        onNavigateSources()
                    } else {
                        Task { await store.checkAgain(id: id) }
                    }
                } catch {
                    onError(error.localizedDescription)
                }
            },
            onQuickReply: { text in
                do {
                    try store.enqueueIndependentMessage(text)
                } catch {
                    onError(error.localizedDescription)
                }
            }
        )
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DesktopHomeSuggestionsHost: View {
    let store: RemoteTaskStore
    let briefingDocument: DreamBriefingDocument?
    let compact: Bool
    @Binding var dismissedBriefingCardIDs: Set<String>
    let onSent: () -> Void
    let onOpenBriefing: () -> Void
    let onOpenNotebook: () -> Void
    let onError: (String) -> Void

    var body: some View {
        if !store.hasDraftContent,
           !store.hasActiveTask,
           let doc = briefingDocument,
           !doc.cards.filter({ !$0.isDismissed(in: dismissedBriefingCardIDs, headline: doc.headline) }).isEmpty {
            DreamHomeCardsSection(
                document: doc,
                dismissedIDs: $dismissedBriefingCardIDs,
                compact: compact,
                onSelectCard: { card in
                    do {
                        try store.enqueueIndependentMessage(card.prompt)
                        onSent()
                        Task { await store.refresh(userInitiated: true) }
                    } catch {
                        onError(error.localizedDescription)
                    }
                },
                onOpenBriefing: onOpenBriefing,
                onOpenNotebook: onOpenNotebook
            )
            .padding(.top, compact ? 6 : 2)
            .padding(.bottom, compact ? 4 : 6)
        }
    }
}

/// Codex-aligned 30pt segmented capsule for switching Standard vs Creator mode in the top gray chrome bar.
private struct DesktopChatModeCapsule: View {
    let store: RemoteTaskStore
    @State private var currentMode: ChatMode = .standard
    @State private var loaded = false
    @State private var switching = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 1) {
            modeOption(.standard, title: "日常")
            modeOption(.creator, title: "创作")
        }
        .padding(3)
        .frame(height: 30)
        .background(
            MoMoPalette.ink.opacity(colorScheme == .dark ? 0.075 : 0.048),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .task(id: ObjectIdentifier(store)) {
            if let fetched = try? await store.chatMode() {
                currentMode = fetched
                loaded = true
            }
        }
        .opacity(loaded ? 1 : 0.75)
    }

    private func modeOption(_ mode: ChatMode, title: String) -> some View {
        let selected = currentMode == mode
        return Button {
            guard !switching, currentMode != mode else { return }
            let previous = currentMode
            currentMode = mode
            switching = true
            Task {
                defer { switching = false }
                if let updated = try? await store.chatMode(setting: mode) {
                    currentMode = updated
                } else {
                    currentMode = previous
                }
            }
        } label: {
            Text(LocalizedStringKey(title))
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? MoMoPalette.ink : MoMoPalette.ink.opacity(0.62))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(MoMoPalette.paper)
                            .shadow(
                                color: colorScheme == .dark ? .clear : Color.black.opacity(0.06),
                                radius: 2,
                                x: 0,
                                y: 1
                            )
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode == .creator ? "切换至深度创作模式" : "切换至日常对话模式")
    }
}

private struct DesktopComposerHost: View {
    let store: RemoteTaskStore
    var focusRequestToken: UInt64 = 0
    let onSent: () -> Void
    let onPreviewAttachment: (AgentAttachment) -> Void
    let onError: (String) -> Void

    var body: some View {
        ClientComposer(
            text: Binding(get: { store.draft }, set: { store.setDraft($0) }),
            store: store,
            inputID: "desktop.message",
            sendID: "desktop.send",
            prompt: "发消息给 MoMo…",
            focusRequestToken: focusRequestToken,
            onPreviewAttachment: onPreviewAttachment,
            onError: onError
        ) {
            do {
                try store.enqueue()
                onSent()
                Task { await store.refresh(userInitiated: true) }
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}

private struct DesktopActiveTasksBadgeButton: View {
    let store: RemoteTaskStore?
    @Binding var showingActiveTasks: Bool
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        let tasksSnap = AgentActiveTasksSnapshot(store: store)
        Button {
            withAnimation(reducedMotion ? nil : DesktopRightInspectorContainer<EmptyView>.toggleAnimation) {
                showingActiveTasks.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                if tasksSnap.count > 0 {
                    SandWorkingDots()
                } else {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 14.5, weight: .regular))
                        .accessibilityHidden(true)
                }
                Text("任务")
                    .font(.system(size: 13, weight: .medium))
                if let badge = tasksSnap.badgeText {
                    Text(badge)
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(MoMoPalette.ink)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(MoMoPalette.ink.opacity(0.10), in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(showingActiveTasks || hovered ? MoMoPalette.ink : MoMoPalette.ink.opacity(0.62))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                showingActiveTasks ? MoMoPalette.activeFill : (hovered ? MoMoPalette.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(MoMoPressableButtonStyle(scale: 0.96))
        .onHover { hovered = $0 }
        .help(showingActiveTasks ? "收起任务详情栏" : "展开正在进行的任务")
        .accessibilityLabel(tasksSnap.count > 0 ? LocalizedStringKey("正在进行的任务，\(tasksSnap.count) 项") : LocalizedStringKey("正在进行的任务"))
        .accessibilityIdentifier("desktop.activeTasks")
    }
}

struct DesktopSettings: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "通用", model = "模型", speech = "声纹与转录", pairing = "设备", connectors = "连接器", controls = "电脑控制", runtime = "运行环境"
        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .model: "sparkles"
            case .speech: "person.wave.2"
            case .pairing: "iphone"
            case .connectors: "link.circle"
            case .controls: "cursorarrow.click"
            case .runtime: "cpu"
            }
        }
    }

    private enum Location: Equatable {
        case pane(Page)
        case connectionMethod

        var page: Page {
            switch self {
            case .pane(let page): page
            case .connectionMethod: .pairing
            }
        }

        var title: LocalizedStringKey {
            self == .connectionMethod ? "连接方式" : LocalizedStringKey(page.rawValue)
        }
    }

    @Bindable var model: DesktopModel
    @State private var history: [Location] = [.pane(.general)]
    @State private var index = 0
    @State private var search = ""
    @State private var permissions = DesktopPermissionsController()
    @State private var showingEngineTasks = false
    @State private var showingProactivePromptEditor = false
    private var location: Location { history[index] }
    private var page: Page { location.page }

    private func navigate(_ next: Location) {
        guard next != location else { return }
        history.removeSubrange((index + 1)..<history.count)
        history.append(next)
        index += 1
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: Binding(get: { page }, set: { navigate(.pane($0)) })) {
                ForEach(matchingPages) { destination in
                    Label(LocalizedStringKey(destination.rawValue), systemImage: destination.icon)
                        .symbolVariant(.none)
                        .symbolRenderingMode(.monochrome)
                    .tag(destination)
                    .accessibilityIdentifier("settings." + destination.rawValue)
                }
                if matchingPages.isEmpty {
                    Text("没有匹配的设置").font(.callout).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .searchable(text: $search, placement: .sidebar, prompt: Text("搜索"))
            .onSubmit(of: .search) { if let first = matchingPages.first { navigate(.pane(first)) } }
            .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 240)
        } detail: {
            Group {
                switch page {
                case .model: modelSettings
                case .speech: DesktopVoiceprintsAndSpeechView(model: model)
                case .pairing:
                    DesktopDevices(model: model, showingMethod: Binding(
                        get: { location == .connectionMethod },
                        set: { show in
                            if show { navigate(.connectionMethod) }
                            else if index > 0, history[index - 1] == .pane(.pairing) { index -= 1 }
                            else { navigate(.pane(.pairing)) }
                        }
                    ))
                case .connectors: DesktopConnectorsView(model: model)
                case .general, .controls, .runtime: preferences
                }
            }
            .navigationTitle(location.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button("后退", systemImage: "chevron.backward") { index -= 1 }
                        .disabled(index == 0).keyboardShortcut("[", modifiers: .command)
                        .accessibilityIdentifier("settings.back")
                    Button("前进", systemImage: "chevron.forward") { index += 1 }
                        .disabled(index + 1 >= history.count).keyboardShortcut("]", modifiers: .command)
                        .accessibilityIdentifier("settings.forward")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 680, idealWidth: 790, minHeight: 450, idealHeight: 540)
        .environment(\.desktopSettingsDensity, true)
        .onAppear {
            model.loadLifePulseConfiguration()
            if model.managingModel { open(.model); model.managingModel = false }
            else if model.managingConnection { open(.pairing); model.managingConnection = false }
        }
        .sheet(isPresented: $showingProactivePromptEditor) {
            DesktopProactivePromptEditorSheet(model: model)
        }
        .onChange(of: model.managingConnection) { _, show in
            if show { open(.pairing); model.managingConnection = false }
        }
        .onChange(of: model.managingModel) { _, show in
            if show { open(.model); model.managingModel = false }
        }
    }

    private func open(_ page: Page) {
        search = ""
        navigate(.pane(page))
    }

    private var matchingPages: [Page] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Page.allCases }
        return Page.allCases.filter { destination in
            let terms: [String]
            switch destination {
            case .general: terms = [String(localized: "通用"), String(localized: "主动守护"), String(localized: "巡检频率"), String(localized: "勿扰时段"), String(localized: "守护规则"), "Life Pulse", String(localized: "提示词"), String(localized: "时间线"), String(localized: "凌晨记录默认折叠至"), String(localized: "生活插画")]
            case .controls: terms = [String(localized: "电脑控制"), String(localized: "屏幕与控制权限"), String(localized: "连接与权限")]
            case .runtime: terms = [String(localized: "运行环境"), String(localized: "智能体引擎"), String(localized: "应用更新"), String(localized: "结果文件夹"), "DeepSeek Harness", "SuperAgent", "Proactive"]
            case .model: terms = [String(localized: "模型"), String(localized: "聊天模式"), String(localized: "创作"), "Creator", "API", "Codex", "Claude"]
            case .speech: terms = [String(localized: "声纹与转录"), String(localized: "声纹"), String(localized: "转录"), String(localized: "说话人"), "MOSS", "ReDimNet2", "Core ML", String(localized: "热词")]
            case .pairing: terms = [String(localized: "设备"), String(localized: "配对手机"), String(localized: "网络代理"), "Tailscale", String(localized: "远程访问")]
            case .connectors: terms = [String(localized: "连接器"), String(localized: "飞书"), "Feishu", "Lark", String(localized: "邮件"), "Email", "Composio", "Outlook", "Gmail", "OAuth"]
            }
            return terms.contains { $0.localizedStandardContains(query) }
        }
    }

    private var modelSettings: some View {
        Form {
            if let notice = model.taskStore?.providerNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: notice.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(verbatim: notice.message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityIdentifier("settings.providerNotice")
            }
            if let store = model.taskStore {
                ChatModeSettings(store: store)
            }
            Section("接入方式") {
                ModelConnectionFields(model: model)
            }
            if model.status?.agentOnline == true {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MoMo 正在运行").font(.system(size: 14))
                        Text("可直接点击「更换接入服务」切换供应商或模型，保存时将自动重启生效").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("停止运行") { model.stopAgent() }
                        .buttonStyle(.bordered)
                        .disabled(!model.ownsAgent).accessibilityIdentifier("settings.stopAgent")
                }
            }
            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
            if let failure = model.failure { Text(failure).font(.callout).foregroundStyle(MoMoPalette.failure).textSelection(.enabled) }
        }
        .formStyle(.grouped)
    }

    private var preferences: some View {
        Form {
            switch page {
            case .general: dailyPreferences
            case .controls: controlPreferences
            case .runtime: runtimePreferences
            case .model, .pairing, .connectors, .speech: EmptyView()
            }
        }
        .formStyle(.grouped)
        .task(id: page == .runtime) {
            guard page == .runtime else { return }
            while !Task.isCancelled {
                if model.status?.agentOnline == true {
                    await model.refreshProactiveSnapshot()
                }
                do { try await Task.sleep(for: .seconds(8)) } catch { break }
            }
        }
    }

    @ViewBuilder private var dailyPreferences: some View {
        Section("主动守护") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("触发频率").font(.system(size: 14))
                    Text("MoMo 后台综合日程、录音、飞书与状态主动评估的间隔。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Picker("触发频率", selection: Binding(
                    get: { model.lifePulseConfig.intervalMinutes },
                    set: { mins in
                        var next = model.lifePulseConfig
                        next.intervalMinutes = mins
                        model.updateLifePulseConfiguration(next)
                    }
                )) {
                    let options = DesktopLifePulseConfig.intervalOptions.contains(model.lifePulseConfig.intervalMinutes)
                        ? DesktopLifePulseConfig.intervalOptions
                        : (DesktopLifePulseConfig.intervalOptions + [model.lifePulseConfig.intervalMinutes]).sorted()
                    ForEach(options, id: \.self) { mins in
                        Text(DesktopLifePulseConfig.intervalLabel(for: mins)).tag(mins)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.lifePulse.interval")
            }

            Toggle(isOn: Binding(
                get: { model.lifePulseConfig.quietEnabled },
                set: { enabled in
                    var next = model.lifePulseConfig
                    next.quietEnabled = enabled
                    model.updateLifePulseConfiguration(next)
                }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("勿扰时段").font(.system(size: 14))
                    Text("该时段内默认静默，除非临近日程、运动或刚醒来。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("settings.lifePulse.quietEnabled")

            if model.lifePulseConfig.quietEnabled {
                HStack(spacing: 10) {
                    Text("静默时间").font(.system(size: 13.5)).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Picker("开始", selection: Binding(
                        get: { model.lifePulseConfig.quietStart },
                        set: { value in
                            var next = model.lifePulseConfig
                            next.quietStart = value
                            model.updateLifePulseConfiguration(next)
                        }
                    )) {
                        let opts = DesktopLifePulseConfig.halfHourOptions.contains(model.lifePulseConfig.quietStart)
                            ? DesktopLifePulseConfig.halfHourOptions
                            : [model.lifePulseConfig.quietStart] + DesktopLifePulseConfig.halfHourOptions
                        ForEach(opts, id: \.self) { hm in
                            Text(hm).tag(hm)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.lifePulse.quietStart")

                    Text("至").font(.system(size: 13)).foregroundStyle(.secondary)

                    Picker("结束", selection: Binding(
                        get: { model.lifePulseConfig.quietEnd },
                        set: { value in
                            var next = model.lifePulseConfig
                            next.quietEnd = value
                            model.updateLifePulseConfiguration(next)
                        }
                    )) {
                        let opts = DesktopLifePulseConfig.halfHourOptions.contains(model.lifePulseConfig.quietEnd)
                            ? DesktopLifePulseConfig.halfHourOptions
                            : [model.lifePulseConfig.quietEnd] + DesktopLifePulseConfig.halfHourOptions
                        ForEach(opts, id: \.self) { hm in
                            Text(hm).tag(hm)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.lifePulse.quietEnd")
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("守护规则（Markdown）").font(.system(size: 14))
                    Text("以 PROACTIVE_PREFERENCES.md 存储，你和 MoMo 都可直接编辑。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button("编辑规则") { showingProactivePromptEditor = true }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.lifePulse.editPrompt")
            }
        }

        Section("时间线") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("凌晨记录默认折叠至").font(.system(size: 14))
                    Text("只折叠显示，不改变录音日期。默认 08:00。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if model.dayStartHour != TranscriptReadingBoundary.defaultHour {
                    Button("恢复默认") { model.selectDayStartHour(TranscriptReadingBoundary.defaultHour) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.dayStartHour.reset")
                }
                Picker("凌晨记录默认折叠至", selection: Binding(
                    get: { model.dayStartHour },
                    set: { model.selectDayStartHour($0) }
                )) {
                    ForEach(Array(TranscriptReadingBoundary.hourRange), id: \.self) { hour in
                        Text(TranscriptReadingBoundary.label(for: hour)).tag(hour)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings.dayStartHour")
            }
        }
        Section {
            VStack(alignment: .leading, spacing: 7) {
                LifeIllustrationSettingsControls(store: model.lifeIllustrations)
            }
            .toggleStyle(.switch).controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var controlPreferences: some View {
        Section("电脑控制") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("屏幕与控制权限").font(.system(size: 14))
                    Text("在系统设置「隐私与安全性」开启辅助功能与屏幕录制后，MoMo 与配对手机可查看和操作电脑")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Button("管理") { permissions.present() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.permissions")
            }
            HStack {
                Text("电脑控制权").fontWeight(.regular)
                Spacer()
                if model.desktopHost?.humanHasControl == true {
                    Button("交还 MoMo") {
                        do { try model.desktopHost?.returnControl() }
                        catch { model.desktopFailure = error.localizedDescription }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings.returnControl")
                } else {
                    Text(model.desktopHost == nil ? "尚未连接" : "MoMo").foregroundStyle(.secondary)
                }
            }
            if let error = model.desktopFailure { Text(error).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure) }
        }
    }

    @ViewBuilder private var runtimePreferences: some View {
        Section("智能体引擎") {
            HStack {
                Text("Agent Runtime").font(.system(size: 14))
                Spacer(minLength: 16)
                Text("DeepSeek Harness").foregroundStyle(.secondary)
            }
            if let snap = model.proactiveSnapshot {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("引擎状态").font(.system(size: 14))
                        Text(snap.dshReady
                             ? String(localized: "已就绪 · 进行中 \(snap.activeTickets) · 已分析 \(snap.totalDecisions)")
                             : String(localized: "正在启动 DeepSeek SuperAgent…"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("查看任务") { showingEngineTasks.toggle() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.superagentTasks")
                        .popover(isPresented: $showingEngineTasks, arrowEdge: .bottom) {
                            AgentActiveTasksSheet(store: model.taskStore, isPopover: true)
                                .frame(width: 420)
                                .frame(minHeight: 300, maxHeight: 540)
                        }
                }
            }
        }
        Section("运行环境") {
            if model.hasBundledRuntime {
                HStack {
                    Text("运行组件")
                    Spacer()
                    Text("已内置").foregroundStyle(.secondary)
                }
            } else {
                settingsAction("运行组件", action: "准备", id: "settings.prepareRuntime", disabled: model.busy != nil) {
                    Task { await model.prepare() }
                }
            }
            settingsAction("应用更新", action: "获取更新", id: "settings.getUpdates") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Miri-Labs/MoMo-Agent/releases/latest")!)
            }
            settingsAction("结果文件夹", action: "打开", id: "settings.openResults") { model.showFiles() }
            if let busy = model.busy { ProgressView(busy).controlSize(.small) }
            if let failure = model.failure { Text(failure).font(.system(size: 12)).foregroundStyle(MoMoPalette.failure) }
        }
    }

    private func settingsAction(_ title: String, action label: String, id: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.system(size: 14))
            Spacer()
            Button(LocalizedStringKey(label), action: perform)
                .buttonStyle(.bordered)
                .disabled(disabled).accessibilityIdentifier(id)
        }
    }
}

/// The presentation owns its measured height so each pairing step can resize the sheet.
private struct DesktopPairingSheet: View {
    let model: DesktopModel
    let onFinish: () -> Void
    @State private var contentHeight: CGFloat = 360

    var body: some View {
        if #available(macOS 15, *) {
            content.presentationSizing(PairingPresentationSize(height: min(contentHeight, 640)))
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            DesktopOnboardingPairing(model: model, onFinish: onFinish)
                .padding(20).frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }.frame(width: 480, height: min(contentHeight, 640))
    }
}

@available(macOS 15, *)
private struct PairingPresentationSize: PresentationSizing {
    let height: CGFloat

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 480, height: height)
    }
}

extension View {
    func desktopSettingsRow() -> some View {
        frame(minHeight: 20).padding(.vertical, 12)
    }
}

struct DesktopSettingsControlSurface: ViewModifier {
    var active = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .regular))
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(active ? 0.36 : contrast == .increased ? 0.30 : 0.11), lineWidth: active ? 0.85 : 0.5)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// Clean native Markdown editor sheet for `memories/PROACTIVE_PREFERENCES.md` (shared with MoMo AI).
private struct DesktopProactivePromptEditorSheet: View {
    @Bindable var model: DesktopModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("主动守护规则（PROACTIVE_PREFERENCES.md）")
                        .font(.system(size: 15, weight: .semibold))
                    Text("每次 Life Pulse 巡检都会直接读取这份 Markdown；在聊天里让 MoMo 调整也会同步更新此文件。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("在 Finder 中显示") {
                    if !FileManager.default.fileExists(atPath: model.proactivePreferencesURL.path) {
                        try? model.saveProactivePreferencesMarkdown(draft)
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([model.proactivePreferencesURL])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextEditor(text: $draft)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(MoMoPalette.failure)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        try model.saveProactivePreferencesMarkdown(draft)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 600, height: 440)
        .onAppear {
            draft = model.readProactivePreferencesMarkdown()
        }
    }
}
