import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import MoMoAgentClient
import MoMoContracts

struct DesktopRoot: View {
    @Bindable var model: DesktopModel
    @State private var sidebarVisible = true
    @State private var visitedTabs: Set<String> = ["chat"]
    @State private var recordingCitation: RecordingCitation?
    @State private var previewingMemoryNote: ContextMemory?
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible { sidebar.frame(width: 232).transition(.move(edge: .leading).combined(with: .opacity)) }
            VStack(spacing: 0) {
                if let failure = model.failure {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(failure); Spacer(); Button("关闭") { model.failure = nil } }
                        .font(.callout).padding(16).padding(.top, 32)
                        .background(MoMoPalette.failureBackground).accessibilityIdentifier("desktop.failure")
                }
                ZStack {
                    if visitedTabs.contains("chat") || model.selection == "chat" {
                        let active = model.selection == "chat"
                        DesktopChat(model: model, isActive: active)
                            .padding(.top, 28)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                    if visitedTabs.contains("memory") || model.selection == "memory" {
                        let active = model.selection == "memory"
                        DesktopMemory(model: model, isActive: active)
                            .padding(.top, 36)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                    if visitedTabs.contains("sources") || model.selection == "sources" {
                        let active = model.selection == "sources"
                        DesktopSources(model: model, isActive: active)
                            .padding(.top, 36)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: model.selection, initial: true) {
                    visitedTabs.insert(model.selection)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MoMoPalette.canvas)
        }
        .overlay(alignment: .topLeading) {
            if !sidebarVisible { sidebarToggle.padding(.leading, 92).padding(.top, 2) }
        }
        .background(MoMoPalette.paper)
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); sidebarToggle }.padding(.trailing, 16).frame(height: 32)
            HStack(spacing: 10) { PhoneBrandIcon(size: 22); PhoneBrandWordmark(size: 15); Spacer(minLength: 0) }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
            VStack(spacing: 4) {
                destination("首页", icon: "house", selection: "chat")
                destination("记忆", icon: "brain", selection: "memory")
                destination("转录", icon: "waveform", selection: "sources")
            }.padding(.horizontal, 12)
            Spacer(minLength: 24)
            VStack(alignment: .leading, spacing: 14) {
                sidebarLabel(model.status?.agentOnline == true ? "MoMo 正在运行" : "MoMo 尚未运行", icon: model.status?.agentOnline == true ? "checkmark.circle" : "pause.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button { openWindow(id: MoMoAgentMacApp.settingsID) } label: { sidebarLabel("设置", icon: "gearshape").font(.system(size: 15)) }.buttonStyle(.plain)
            }.padding(24)
        }
    }

    private var sidebarToggle: some View {
        Button { withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.2)) { sidebarVisible.toggle() } } label: {
            Image(systemName: "sidebar.left").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(sidebarVisible ? "收起侧栏" : "显示侧栏")
            .accessibilityLabel(sidebarVisible ? "收起侧栏" : "显示侧栏").accessibilityIdentifier("desktop.sidebarToggle")
            .keyboardShortcut("s", modifiers: [.command, .control])
    }

    private func sidebarLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).accessibilityHidden(true)
            Text(LocalizedStringKey(title))
        }
    }

    private func destination(_ title: String, icon: String, selection: String) -> some View {
        Button { model.selection = selection } label: {
            sidebarLabel(title, icon: icon).font(.system(size: 15))
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).padding(.horizontal, 12)
                .background(model.selection == selection ? MoMoPalette.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityIdentifier("desktop.destination." + selection)
            .accessibilityAddTraits(model.selection == selection ? .isSelected : [])
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
                if model.status?.tunnel.state == "connected" { _ = await model.control("pair/invite") }
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
    @State private var composeRevision = 0
    @State private var previewAttachment: AgentAttachment?
    @State private var showingActiveTasks = false
    @State private var dismissedBriefingCardIDs: Set<String> = DreamDismissedCardsStore.load()
    @State private var showingBriefingDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    private var briefingDocument: DreamBriefingDocument? {
        model.vaultSnapshot.briefingDocument
    }

    var body: some View {
        VStack(spacing: 0) {
            if let store = model.taskStore {
                let snapshot = ChatRenderSnapshot(store: store, readingPosition: model.readingPosition)
                let isEmpty = store.isEmpty || snapshot.messages.isEmpty
                let draftEmpty = store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                VStack(spacing: isEmpty ? 18 : 6) {
                    PersonalAgentSlot(size: isEmpty ? 144 : 56, active: isActive && store.hasActiveTask, expression: store.hasActiveTask ? .thinking : .present)
                    PhoneBrandWordmark(.momo, size: isEmpty ? 22 : 12)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: isEmpty ? .infinity : nil)
                .padding(.top, isEmpty ? 0 : 12)
                .padding(.bottom, isEmpty ? 0 : 8)
                .zIndex(1)
                if !isEmpty {
                    ChatRendererView(snapshot: snapshot, scrollToBottomRequest: composeRevision, isChatVisible: isActive && !showingActiveTasks && !showingBriefingDetail && previewAttachment == nil, isChatSelected: isActive, headerInset: headerOverlap, onReadingPosition: model.rememberReadingPosition,
                        onAttachment: { id in previewAttachment = store.attachment(id: id) },
                        onRetryMessage: { id in Task { await store.checkAgain(id: id) } })
                        .frame(maxWidth: 780)
                        .padding(.top, -headerOverlap)
                }
                if draftEmpty, !store.hasActiveTask, let doc = briefingDocument,
                   !doc.cards.filter({ !$0.isDismissed(in: dismissedBriefingCardIDs, headline: doc.headline) }).isEmpty {
                    DreamHomeCardsSection(
                        document: doc,
                        dismissedIDs: $dismissedBriefingCardIDs,
                        compact: !isEmpty,
                        onSelectCard: { card in
                            store.setDraft(card.prompt)
                            do {
                                try store.enqueue()
                                composeRevision += 1
                                Task { await store.refresh(userInitiated: true) }
                            } catch {
                                model.failure = error.localizedDescription
                            }
                        },
                        onOpenBriefing: { showingBriefingDetail = true },
                        onOpenNotebook: { model.selection = "memory" }
                    )
                    .frame(maxWidth: 760)
                    .padding(.top, isEmpty ? 0 : 8)
                    .padding(.bottom, 6)
                }
                RemoteTaskControlsView(store: store, returnDesktop: {
                    do { try model.desktopHost?.returnControl() }
                    catch { model.failure = error.localizedDescription }
                }).frame(maxWidth: 780)
                RemoteTaskRecoveryView(store: store).frame(maxWidth: 780)
                if let failure = store.interactionFailure { Text(failure).font(.footnote).foregroundStyle(MoMoPalette.failure) }
                ClientComposer(text: Binding(get: { store.draft }, set: store.setDraft),
                               store: store,
                               inputID: "desktop.message", sendID: "desktop.send",
                               prompt: "发消息给 MoMo",
                               onCompose: { composeRevision += 1 },
                               onPreviewAttachment: { previewAttachment = $0 },
                               onError: { model.failure = $0 }) {
                    do { try store.enqueue(); Task { await store.refresh(userInitiated: true) } } catch { model.failure = error.localizedDescription }
                }.frame(maxWidth: 760).padding(.horizontal, 32).padding(.bottom, 24).padding(.top, 12)
            } else {
                Spacer(); PersonalAgentSlot(size: 144, active: false, expression: .concerned)
                PhoneBrandWordmark(.momo, size: 24).padding()
                Text("MoMo 暂时没有连接上").phoneText(.heading)
                Button("检查连接") {
                    model.managingConnection = true
                    openWindow(id: MoMoAgentMacApp.settingsID)
                }
                    .buttonStyle(DesktopSetupButton(minimumHeight: 48, fontSize: 14)).frame(width: 240).padding(); Spacer()
            }
        }.frame(maxWidth: .infinity).background(MoMoPalette.canvas)
            .overlay(alignment: .topTrailing) {
                desktopActiveTasksButton(store: model.taskStore)
                    .padding(.top, 14)
                    .padding(.trailing, 18)
            }
            .task { if model.memories.isEmpty { await model.loadContextIfStale(maxAge: 15) } }
            .sheet(item: $previewAttachment) { ClientAttachmentPreview(attachment: $0) }
            .sheet(isPresented: $showingBriefingDetail) {
                if let doc = briefingDocument {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(doc.headline).phoneText(.heading)
                            Spacer()
                            Button("完成") { showingBriefingDetail = false }
                                .buttonStyle(.plain)
                        }
                        Divider()
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
            .animation(reduced ? nil : .spring(response: 0.5, dampingFraction: 0.86), value: model.taskStore?.tasks.isEmpty)
    }

    private func desktopActiveTasksButton(store: RemoteTaskStore?) -> some View {
        let tasksSnap = AgentActiveTasksSnapshot(store: store)
        return Button {
            showingActiveTasks.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityHidden(true)
                Text("任务")
                    .font(.system(size: 12, weight: .medium))
                if let badge = tasksSnap.badgeText {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MoMoPalette.canvas)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(MoMoPalette.ink, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(MoMoPalette.ink)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(MoMoPalette.paper, in: Capsule())
            .overlay { Capsule().strokeBorder(MoMoPalette.line, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("正在进行的任务")
        .accessibilityLabel(tasksSnap.count > 0 ? LocalizedStringKey("正在进行的任务，\(tasksSnap.count) 项") : LocalizedStringKey("正在进行的任务"))
        .accessibilityIdentifier("desktop.activeTasks")
        .popover(isPresented: $showingActiveTasks, arrowEdge: .bottom) {
            AgentActiveTasksSheet(store: store, isPopover: true)
                .frame(width: 420)
                .frame(minHeight: 300, maxHeight: 540)
        }
    }
}

struct DesktopSettings: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "通用", model = "模型", pairing = "设备", controls = "电脑控制", runtime = "运行环境"
        var id: Self { self }
        var icon: String {
            switch self {
            case .general: "gearshape"
            case .model: "sparkles"
            case .pairing: "iphone"
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
                case .pairing:
                    DesktopDevices(model: model, showingMethod: Binding(
                        get: { location == .connectionMethod },
                        set: { show in
                            if show { navigate(.connectionMethod) }
                            else if index > 0, history[index - 1] == .pane(.pairing) { index -= 1 }
                            else { navigate(.pane(.pairing)) }
                        }
                    ))
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
            if model.managingModel { open(.model); model.managingModel = false }
            else if model.managingConnection { open(.pairing); model.managingConnection = false }
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
            case .general: terms = [String(localized: "通用"), String(localized: "时间线"), String(localized: "每天起点"), String(localized: "生活插画")]
            case .controls: terms = [String(localized: "电脑控制"), String(localized: "屏幕与控制权限"), String(localized: "连接与权限")]
            case .runtime: terms = [String(localized: "运行环境"), String(localized: "智能体引擎"), String(localized: "应用更新"), String(localized: "结果文件夹"), "DeepSeek Harness", "SuperAgent", "Proactive"]
            case .model: terms = [String(localized: "模型"), String(localized: "聊天模式"), String(localized: "创作"), "Creator", "API", "Codex", "Claude", "Antigravity", "Gemini"]
            case .pairing: terms = [String(localized: "设备"), String(localized: "配对手机"), String(localized: "网络代理"), "Tailscale", String(localized: "远程访问")]
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
            case .model, .pairing: EmptyView()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var dailyPreferences: some View {
        Section("时间线") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每天起点").font(.system(size: 14))
                    Text("早于该时间的凌晨录音会归入前一天。默认 08:00。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if model.dayStartHour != DayStartBoundary.defaultHour {
                    Button("恢复默认") { model.selectDayStartHour(DayStartBoundary.defaultHour) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("settings.dayStartHour.reset")
                }
                Picker("每天起点", selection: Binding(
                    get: { model.dayStartHour },
                    set: { model.selectDayStartHour($0) }
                )) {
                    ForEach(Array(DayStartBoundary.hourRange), id: \.self) { hour in
                        Text(DayStartBoundary.label(for: hour)).tag(hour)
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
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(active ? 0.45 : contrast == .increased ? 0.35 : 0.14), lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.4)
    }
}
