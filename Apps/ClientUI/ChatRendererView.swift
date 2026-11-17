import SwiftUI
import WebKit
import OSLog
import MoMoContracts

struct ChatScrollRequest: Equatable {
    enum Destination { case entry, resumeTab, latest }
    let destination: Destination
    let id = UUID()
}

/// Offline presentation surface. It cannot execute agent tools or access provider configuration.
struct ChatRendererView: View {
    let snapshot: ChatRenderSnapshot
    var scrollToBottomRequest = 0
    var isChatVisible = true
    var isChatSelected = true
    var headerInset: CGFloat = 0
    var onRegenerate: (String) -> Void = { _ in }
    var onReadingPosition: (ChatReadingPosition) -> Void = { _ in }
    var onSystemAction: (UUID) -> Void = { _ in }
    var onAttachment: (UUID) -> Void = { _ in }
    var onRetryMessage: (UUID) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var fontSize = Double(PhoneTextStyle.body.size)
    @State private var scrollRequest = ChatScrollRequest(destination: .entry)
    @State private var renderingFailed = false
    @State private var rendererReady = ChatWebSurface.hasWarmRenderedView
    @State private var nativeFocusedRequest: String?
    @State private var nativeEntryPlaced = false

    var body: some View {
        VStack(spacing: 0) {
            if renderingFailed {
                Text("消息暂以文字显示")
                    .phoneText(.metadata).foregroundStyle(.secondary)
                    .padding(.top, headerInset)
                    .accessibilityIdentifier("assistant.renderingFailure")
                Button("重新加载消息") { rendererReady = false; renderingFailed = false }
                    .accessibilityIdentifier("assistant.reloadRendering")
                plainTranscript
            } else {
                ZStack(alignment: .top) {
                    ChatWebSurface(snapshot: snapshot, scrollRequest: scrollRequest, dark: colorScheme == .dark,
                        reduceMotion: reduceMotion, scale: fontSize / Double(PhoneTextStyle.body.size), headerInset: headerInset, active: isChatVisible && scenePhase == .active,
                        failed: { renderingFailed = true }, rendered: { rendererReady = true },
                        recovering: { rendererReady = false },
                        open: { openURL($0) }, regenerate: onRegenerate,
                        readingPosition: onReadingPosition, systemAction: onSystemAction, attachment: onAttachment, retryMessage: onRetryMessage)
                        .opacity(rendererReady ? 1 : 0)
                        .accessibilityHidden(!rendererReady)
                        .accessibilityIdentifier("assistant.transcript")
                    if !rendererReady { plainTranscript }
                }
            }
        }
        .background(MoMoPalette.canvas)
        .phoneSoftTopEdge()
        .onChange(of: isChatSelected) { _, selected in
            if selected { scrollRequest = ChatScrollRequest(destination: .resumeTab) }
        }
        .onChange(of: scrollToBottomRequest) { scrollRequest = ChatScrollRequest(destination: .latest) }
        .onChange(of: snapshot.sessionID) { renderingFailed = false; scrollRequest = ChatScrollRequest(destination: .entry) }
        .onChange(of: scenePhase) {
            if scenePhase == .active, renderingFailed { rendererReady = false; renderingFailed = false }
        }
    }

    private func typingOpacity(at date: Date, index: Int) -> Double {
        let phase = (date.timeIntervalSinceReferenceDate - Double(index) * 0.25).truncatingRemainder(dividingBy: 1)
        let distance = min(phase, 1 - phase)
        return 0.2 + 0.05 * (1 + cos(.pi * min(distance / 0.37, 1)))
    }

    // First send paints natively while WebKit starts; no network or rich renderer admission is required.
    private var plainTranscript: some View {
        let typeScale = fontSize / Double(PhoneTextStyle.body.size)
        #if os(macOS)
        let bubbleFontSize: CGFloat = 14
        #else
        let bubbleFontSize: CGFloat = 16
        #endif
        let markers = snapshot.nativeTimestampMarkers()
        return GeometryReader { geometry in
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(snapshot.messages.enumerated()), id: \.element.id) { index, message in
                        let body = message.blocks.filter { $0.type == "text" }.compactMap(\.text).joined()
                        let text = body.isEmpty ? message.blocks.filter { $0.type == "attachment" }.compactMap(\.name).joined(separator: "\n") : body
                        if !text.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                if let marker = markers[message.id] {
                                    Text(marker)
                                        .font(.system(size: 12 * typeScale, weight: .regular))
                                        .foregroundStyle(MoMoPalette.muted)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, index == 0 ? 0 : 4)
                                        .padding(.bottom, 12)
                                }
                                if message.role == "user" {
                                    HStack(alignment: .center, spacing: 8) {
                                        Spacer(minLength: 0)
                                        Text(text)
                                            .font(.system(size: bubbleFontSize * typeScale, weight: .regular))
                                            .tracking(-0.01 * bubbleFontSize * typeScale)
                                            .lineSpacing(2 * typeScale)
                                            .textSelection(.enabled)
                                            .foregroundStyle(MoMoPalette.canvas)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                            .background(MoMoPalette.ink, in: .rect(cornerRadius: 22))
                                            .frame(maxWidth: max(0, geometry.size.width - 40) * 0.85, alignment: .trailing)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        let delivered = snapshot.deliveryReceiptMessageID == message.id
                                        Text(message.delivery == "read" ? "已读" : "已送达", bundle: AppLanguage.resourceBundle)
                                            .font(.system(size: 12 * typeScale)).foregroundStyle(.secondary)
                                            .frame(height: 16).offset(y: 18)
                                            .opacity(delivered ? 1 : 0).accessibilityHidden(!delivered)
                                            .allowsHitTesting(false)
                                            .contentTransition(.identity)
                                            .animation(reduceMotion ? nil : .timingCurve(0.19, 1, 0.22, 1, duration: 0.3), value: delivered)
                                    }
                                    .padding(.trailing, -8).padding(.bottom, 2)
                                    if message.delivery == "failed", let id = UUID(uuidString: message.turnID) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Spacer(minLength: 0)
                                            Text(message.deliveryError ?? String(localized: "发送失败", bundle: AppLanguage.resourceBundle))
                                                .multilineTextAlignment(.trailing)
                                            Button { onRetryMessage(id) } label: {
                                                Text(message.deliveryAction ?? String(localized: "重试", bundle: AppLanguage.resourceBundle))
                                                    .underline().frame(minHeight: 44)
                                            }
                                            .buttonStyle(.plain)
                                            .accessibilityLabel(message.deliveryAction ?? String(localized: "发送失败，点击重试", bundle: AppLanguage.resourceBundle))
                                        }.font(.footnote).foregroundStyle(MoMoPalette.failure)
                                    }
                                } else if message.role == "system" {
                                    Text(text).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                        .padding(.leading, 10).padding(.vertical, 4)
                                } else {
                                    Text(text)
                                        .font(.system(size: bubbleFontSize * typeScale, weight: .regular))
                                        .tracking(-0.01 * bubbleFontSize * typeScale)
                                        .lineSpacing(2 * typeScale)
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 16).padding(.vertical, 10)
                                        .background(MoMoPalette.surface, in: .rect(cornerRadius: 22))
                                        .frame(maxWidth: max(0, geometry.size.width - 40) * 0.85, alignment: .leading)
                                }
                            }.id(message.id)
                        }
                    }
                    let waiting = snapshot.waitingForReply ?? (snapshot.busy && snapshot.messages.last?.role == "user")
                    let reserveReply = !snapshot.stopped && snapshot.messages.last?.role == "user" && snapshot.messages.last?.delivery != "failed"
                    if waiting || reserveReply {
                        TimelineView(.animation(minimumInterval: 0.1, paused: !waiting || reduceMotion || scenePhase != .active)) { clock in
                            HStack(spacing: 4) {
                                ForEach(0..<3) { index in
                                    Circle().fill(MoMoPalette.ink)
                                        .opacity(reduceMotion ? 0.3 : typingOpacity(at: clock.date, index: index))
                                        .frame(width: 8, height: 8)
                                }
                            }.frame(width: 56, height: 40).background(MoMoPalette.surface, in: Capsule())
                        }
                        .frame(height: 44, alignment: .topLeading)
                        .opacity(waiting ? 1 : 0).accessibilityHidden(!waiting)
                        .accessibilityElement(children: .ignore).accessibilityLabel("助理正在回复")
                    }
                    Color.clear.frame(height: 1).id("composer-bottom")
                }.padding(.horizontal, 24).padding(.top, 20)
                #if os(macOS)
                .padding(.top, renderingFailed ? 0 : headerInset)
                #endif
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            #if os(iOS)
            .safeAreaPadding(.top, renderingFailed ? 0 : headerInset)
            .scrollDismissesKeyboard(.interactively)
            #endif
            #if os(macOS)
            .overlay(alignment: .top) {
                if !renderingFailed {
                    LinearGradient(colors: [MoMoPalette.canvas, MoMoPalette.canvas.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: headerInset + 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            #endif
            .accessibilityIdentifier("assistant.nativeTranscript")
            .onChange(of: scrollRequest, initial: true) {
                if scrollRequest.destination != .resumeTab { nativeEntryPlaced = false }
                placeNativeChat(reader)
            }
            .onChange(of: snapshot.firstUnreadMessageID) { placeNativeChat(reader) }
            .onChange(of: snapshot.chatEntryReady) { placeNativeChat(reader) }
            .simultaneousGesture(DragGesture().onChanged { _ in nativeEntryPlaced = true })
            .onChange(of: snapshot.focus, initial: true) { _, _ in focusNativeMessage(reader) }
            .onChange(of: snapshot.messages.count) { _, _ in focusNativeMessage(reader) }
            }
        }
    }

    private func placeNativeChat(_ reader: ScrollViewProxy) {
        guard !nativeEntryPlaced, isChatVisible, snapshot.focus == nil else { return }
        if scrollRequest.destination != .latest,
           let position = snapshot.readingPosition, !position.following, let anchor = position.anchorID,
           let message = snapshot.messages.first(where: { ($0.role == "assistant" ? "\($0.id):reply" : $0.id) == anchor }) {
            reader.scrollTo(message.id, anchor: .top)
            nativeEntryPlaced = true
        } else if scrollRequest.destination != .latest, let id = snapshot.firstUnreadMessageID {
            reader.scrollTo(id, anchor: .top)
            nativeEntryPlaced = true
        } else {
            reader.scrollTo("composer-bottom", anchor: .bottom)
            nativeEntryPlaced = scrollRequest.destination == .latest || snapshot.chatEntryReady
        }
    }

    private func focusNativeMessage(_ reader: ScrollViewProxy) {
        guard let focus = snapshot.focus, focus.requestID != nativeFocusedRequest,
              snapshot.messages.contains(where: { $0.id == focus.messageID }) else { return }
        reader.scrollTo(focus.messageID, anchor: .top)
        nativeFocusedRequest = focus.requestID
    }
}

#if os(macOS)
private typealias ChatWebRepresentable = NSViewRepresentable

@MainActor fileprivate final class ChatWKWebView: WKWebView {
    weak var chatCoordinator: ChatWebCoordinator?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        chatCoordinator?.configureMacContextMenu(menu, with: event, in: self)
    }
}

@MainActor fileprivate enum WarmChatWebPool {
    struct Entry {
        let web: ChatWKWebView
        let resourceDirectory: URL
        let documentID: UUID
        let sent: ChatRenderPayload?
        let sentScroll: ChatScrollRequest?
        let didRender: Bool
    }
    static var entry: Entry?
    static func take() -> Entry? {
        defer { entry = nil }
        return entry
    }
}
#else
private typealias ChatWebRepresentable = UIViewRepresentable

@MainActor fileprivate final class ChatWKWebView: WKWebView {}
#endif

struct ChatBubbleRegion: Sendable {
    struct CodeBlock: Sendable {
        let docRect: CGRect
        let viewportRect: CGRect
        let text: String
    }
    let id: String
    let messageID: String
    let isUser: Bool
    let docRect: CGRect
    let viewportRect: CGRect
    let copyText: String
    let codeBlocks: [CodeBlock]
    let interactiveDocRects: [CGRect]
    let interactiveViewportRects: [CGRect]
}

fileprivate struct PressedBubbleState: Sendable {
    let hit: Bool
    let id: String
    let messageID: String
    let isUser: Bool
    let isLink: Bool
    let docX: CGFloat
    let docY: CGFloat
    let dx: CGFloat
    let dy: CGFloat
    let width: CGFloat
    let height: CGFloat
    let copyText: String
    let codeText: String
    let selectedText: String
    let timestamp: ContinuousClock.Instant
}

private struct ChatWebSurface: ChatWebRepresentable {
    static var hasWarmRenderedView: Bool {
        #if os(macOS)
        MainActor.assumeIsolated { WarmChatWebPool.entry?.didRender == true }
        #else
        false
        #endif
    }

    let snapshot: ChatRenderSnapshot
    let scrollRequest: ChatScrollRequest
    let dark: Bool
    let reduceMotion: Bool
    let scale: Double
    let headerInset: CGFloat
    let active: Bool
    let failed: () -> Void
    let rendered: () -> Void
    let recovering: () -> Void
    let open: (URL) -> Void
    let regenerate: (String) -> Void
    let readingPosition: (ChatReadingPosition) -> Void
    let systemAction: (UUID) -> Void
    let attachment: (UUID) -> Void
    let retryMessage: (UUID) -> Void

    func makeCoordinator() -> ChatWebCoordinator {
        let coordinator = ChatWebCoordinator(failed: failed, open: open, regenerate: regenerate, readingPosition: readingPosition, systemAction: systemAction)
        coordinator.rendered = rendered
        coordinator.recovering = recovering
        coordinator.setActive(active)
        coordinator.attachment = attachment
        coordinator.retryMessage = retryMessage
        return coordinator
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) { updateWebView(web, context: context) }
    static func dismantleNSView(_ web: WKWebView, coordinator: ChatWebCoordinator) { dismantleWebView(web, coordinator: coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) { updateWebView(web, context: context) }
    static func dismantleUIView(_ web: WKWebView, coordinator: ChatWebCoordinator) { dismantleWebView(web, coordinator: coordinator) }
    #endif
    private func makeWebView(context: Context) -> WKWebView {
        #if os(macOS)
        if let warm = WarmChatWebPool.take() {
            warm.web.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
            warm.web.configuration.userContentController.add(context.coordinator, name: "chat")
            warm.web.chatCoordinator = context.coordinator
            configureBackground(warm.web)
            warm.web.navigationDelegate = context.coordinator
            context.coordinator.adoptWarm(warm)
            return warm.web
        }
        #endif
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "chat")
        let web = ChatWKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        web.isOpaque = false
        if #available(iOS 26, *) {
            web.scrollView.contentInsetAdjustmentBehavior = .always
            web.scrollView.topEdgeEffect.style = .soft
        } else {
            web.scrollView.contentInsetAdjustmentBehavior = .never
        }
        web.scrollView.keyboardDismissMode = .interactive
        web.scrollView.alwaysBounceVertical = true
        let dismissKeyboard = UIPanGestureRecognizer(target: context.coordinator, action: #selector(ChatWebCoordinator.dismissKeyboardOnDrag(_:)))
        dismissKeyboard.delegate = context.coordinator
        dismissKeyboard.cancelsTouchesInView = false
        web.addGestureRecognizer(dismissKeyboard)
        web.uiDelegate = context.coordinator
        let contextMenu = UIContextMenuInteraction(delegate: context.coordinator)
        web.addInteraction(contextMenu)
        context.coordinator.contextMenuInteraction = contextMenu
        #else
        web.chatCoordinator = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        #endif
        configureBackground(web)
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            context.coordinator.resourceDirectory = url.deletingLastPathComponent()
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            Task { @MainActor in failed() }
        }
        return web
    }

    private func updateWebView(_ web: WKWebView, context: Context) {
        configureBackground(web)
        context.coordinator.failed = failed
        context.coordinator.rendered = rendered
        context.coordinator.recovering = recovering
        context.coordinator.open = open
        context.coordinator.regenerate = regenerate
        context.coordinator.readingPosition = readingPosition
        context.coordinator.systemAction = systemAction
        context.coordinator.attachment = attachment
        context.coordinator.retryMessage = retryMessage
        if !active { context.coordinator.setActive(false) }
        context.coordinator.update(.init(snapshot: snapshot, appearance: .init(dark: dark, reduceMotion: reduceMotion, scale: scale, headerInset: headerInset)), scrollRequest: scrollRequest)
        if active { context.coordinator.setActive(true) }
    }

    private func configureBackground(_ web: WKWebView) {
        // WebKit's first document paint precedes the bridge payload. Match the native canvas
        // immediately, including the overscroll area and prefers-color-scheme evaluation.
        #if os(iOS)
        web.overrideUserInterfaceStyle = dark ? .dark : .light
        web.tintColor = .systemBlue
        let canvas = UIColor(white: dark ? 22 / 255.0 : 250 / 255.0, alpha: 1)
        web.backgroundColor = canvas
        web.scrollView.backgroundColor = canvas
        web.underPageBackgroundColor = canvas
        #else
        web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        web.underPageBackgroundColor = NSColor(white: dark ? 18 / 255.0 : 252 / 255.0, alpha: 1)
        #endif
    }

    private static func dismantleWebView(_ web: WKWebView, coordinator: ChatWebCoordinator) {
        coordinator.setActive(false)
        #if os(macOS)
        if WarmChatWebPool.entry == nil, let chatWeb = web as? ChatWKWebView, let warm = coordinator.exportWarmState(for: chatWeb) {
            chatWeb.chatCoordinator = nil
            coordinator.webView = nil
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
            WarmChatWebPool.entry = warm
            return
        }
        #else
        if let interaction = coordinator.contextMenuInteraction {
            web.removeInteraction(interaction)
            coordinator.contextMenuInteraction = nil
        }
        web.uiDelegate = nil
        #endif
        coordinator.webView = nil
        web.navigationDelegate = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "chat")
        web.stopLoading()
    }
}

#if os(iOS)
extension ChatWebCoordinator: UIGestureRecognizerDelegate {
    @objc func dismissKeyboardOnDrag(_ gesture: UIPanGestureRecognizer) {
        guard activeSelectingBubbleID == nil else { return }
        if let webView, webView.scrollView.subviews.contains(where: { $0.isFirstResponder }) { return }
        let delta = gesture.translation(in: webView)
        if delta.y > 12, delta.y > abs(delta.x) { webView?.window?.endEditing(true) }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard activeSelectingBubbleID == nil else { return false }
        if let webView, webView.scrollView.subviews.contains(where: { $0.isFirstResponder }) { return false }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: webView)
        return velocity.y > 0 && velocity.y > abs(velocity.x)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif

struct ChatRenderPayload: Encodable, Equatable, Sendable {
    struct Appearance: Encodable, Equatable, Sendable {
        let dark: Bool
        let reduceMotion: Bool
        let scale: Double
        var headerInset: CGFloat = 0
        #if os(macOS)
        let desktopHeader = true
        #endif
    }
    let snapshot: ChatRenderSnapshot
    let appearance: Appearance

    func isSameSessionRenderEquivalent(to other: ChatRenderPayload) -> Bool {
        appearance == other.appearance && snapshot.isSameSessionRenderEquivalent(to: other.snapshot)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        try snapshot.encode(to: encoder)
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(appearance, forKey: .appearance)
    }
    private enum Keys: String, CodingKey { case appearance }
}

@MainActor
final class ChatWebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var webView: WKWebView?
    var resourceDirectory: URL?
    var failed: () -> Void
    var open: (URL) -> Void
    var regenerate: (String) -> Void
    var readingPosition: (ChatReadingPosition) -> Void
    var systemAction: (UUID) -> Void
    var attachment: (UUID) -> Void = { _ in }
    var retryMessage: (UUID) -> Void = { _ in }
    var rendered: () -> Void = {}
    var recovering: () -> Void = {}
    var bubbleRegions: [ChatBubbleRegion] = []
    fileprivate var pressedBubble: PressedBubbleState?
    #if os(iOS)
    weak var contextMenuInteraction: UIContextMenuInteraction?
    fileprivate weak var activePreviewHost: UIView?
    fileprivate var activeContextBubbleID: String?
    fileprivate var activeContextBubbleRect: CGRect?
    fileprivate var activeSelectingBubbleID: String?
    fileprivate var pendingInPlaceSelectBubbleID: String?
    #else
    fileprivate var pendingMacCopyText: String?
    fileprivate var pendingMacCodeText: String?
    #endif
    private var active = true
    private var needsReload = false
    private var reloads = 0
    private var documentID = UUID()
    private var recoveryNavigation: WKNavigation?
    private let logger = Logger(subsystem: "com.momoagent.chat", category: "renderer")
    private var didRender = false
    private var ready = false
    private var pending: ChatRenderPayload?
    private var sent: ChatRenderPayload?
    private var sending = false
    private var pendingScroll: ChatScrollRequest?
    private var sentScroll: ChatScrollRequest?
    private var lastFlushTime: ContinuousClock.Instant?
    private var coalescedFlushTask: Task<Void, Never>?

    init(failed: @escaping () -> Void, open: @escaping (URL) -> Void, regenerate: @escaping (String) -> Void = { _ in },
         readingPosition: @escaping (ChatReadingPosition) -> Void = { _ in }, systemAction: @escaping (UUID) -> Void = { _ in }) {
        self.failed = failed; self.open = open; self.regenerate = regenerate
        self.readingPosition = readingPosition
        self.systemAction = systemAction
    }

    func update(_ payload: ChatRenderPayload, scrollRequest: ChatScrollRequest? = nil) {
        pending = payload; pendingScroll = scrollRequest
        scheduleFlush()
    }

    #if os(macOS)
    fileprivate func adoptWarm(_ warm: WarmChatWebPool.Entry) {
        self.webView = warm.web
        self.resourceDirectory = warm.resourceDirectory
        self.documentID = warm.documentID
        self.ready = true
        self.needsReload = false
        self.sent = warm.sent
        self.sentScroll = warm.sentScroll
        self.didRender = warm.didRender
        if warm.didRender {
            self.rendered()
        }
    }

    fileprivate func exportWarmState(for web: ChatWKWebView) -> WarmChatWebPool.Entry? {
        guard ready, !needsReload, !sending, let resourceDirectory else { return nil }
        return WarmChatWebPool.Entry(
            web: web,
            resourceDirectory: resourceDirectory,
            documentID: documentID,
            sent: sent,
            sentScroll: sentScroll,
            didRender: didRender
        )
    }
    #endif

    func setActive(_ value: Bool) {
        let resumed = value && !active
        let suspended = !value && active
        active = value
        if !value {
            coalescedFlushTask?.cancel(); coalescedFlushTask = nil
            if suspended, ready {
                webView?.callAsyncJavaScript(
                    "if (window.MoMoChat?.setSuspended) window.MoMoChat.setSuspended(true);",
                    arguments: [:], in: nil, in: .page, completionHandler: nil
                )
            }
        }
        if resumed {
            reloads = 0
            if needsReload {
                reloadDocument()
            } else {
                if ready {
                    webView?.callAsyncJavaScript(
                        "if (window.MoMoChat?.setSuspended) window.MoMoChat.setSuspended(false);",
                        arguments: [:], in: nil, in: .page, completionHandler: nil
                    )
                }
                flush()
            }
        }
    }

    private func recover(from error: Error) {
        guard webView != nil else { return }
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == URLError.cancelled.rawValue { return }
        logger.error("Render interruption: domain=\(error.domain, privacy: .public) code=\(error.code) active=\(self.active)")
        coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        documentID = UUID(); ready = false; sending = false; needsReload = true
        recovering()
        guard active else { return }
        if reloads < 1 { reloadDocument() } else { failed() }
    }

    private func reloadDocument() {
        guard let webView, let resourceDirectory else { failed(); return }
        coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        reloads += 1; needsReload = false; ready = false; sending = false
        documentID = UUID(); sent = nil; didRender = false; lastFlushTime = nil
        recoveryNavigation = webView.loadFileURL(resourceDirectory.appendingPathComponent("index.html"), allowingReadAccessTo: resourceDirectory)
    }

    private static func streamingTailPatch(from previous: ChatRenderPayload, to next: ChatRenderPayload) -> ChatRenderSnapshot.Message? {
        guard previous.appearance == next.appearance,
              previous.snapshot.sessionID == next.snapshot.sessionID,
              previous.snapshot.locale == next.snapshot.locale,
              previous.snapshot.focus == nil, next.snapshot.focus == nil,
              previous.snapshot.busy == next.snapshot.busy,
              previous.snapshot.stopped == next.snapshot.stopped,
              previous.snapshot.canRegenerate == next.snapshot.canRegenerate,
              previous.snapshot.contextState == next.snapshot.contextState,
              previous.snapshot.waitingForReply == next.snapshot.waitingForReply,
              previous.snapshot.firstUnreadMessageID == next.snapshot.firstUnreadMessageID,
              previous.snapshot.chatEntryReady == next.snapshot.chatEntryReady,
              previous.snapshot.messages.count == next.snapshot.messages.count,
              let prevLast = previous.snapshot.messages.last,
              let nextLast = next.snapshot.messages.last,
              prevLast.state == "streaming", nextLast.state == "streaming",
              prevLast.role == "assistant", nextLast.role == "assistant",
              prevLast.turnID == nextLast.turnID,
              previous.snapshot.messages.dropLast() == next.snapshot.messages.dropLast()
        else { return nil }
        return prevLast == nextLast ? nil : nextLast
    }

    private func scheduleFlush() {
        guard active, ready, !sending, let payload = pending else { return }
        if let sent, pendingScroll == sentScroll, payload.isSameSessionRenderEquivalent(to: sent) {
            self.sent = payload
            return
        }
        guard payload != sent || pendingScroll != sentScroll else { return }
        if let sent,
           pendingScroll == sentScroll,
           payload.appearance == sent.appearance,
           payload.snapshot.sessionID == sent.snapshot.sessionID,
           payload.snapshot.messages.count == sent.snapshot.messages.count,
           payload.snapshot.messages.last?.state == "streaming",
           sent.snapshot.messages.last?.state == "streaming",
           let last = lastFlushTime {
            let elapsed = last.duration(to: .now)
            if elapsed < .milliseconds(16) {
                guard coalescedFlushTask == nil else { return }
                let delay = Duration.milliseconds(16) - elapsed
                coalescedFlushTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard let self else { return }
                    self.coalescedFlushTask = nil
                    self.flush()
                }
                return
            }
        }
        flush()
    }

    private func flush() {
        coalescedFlushTask?.cancel(); coalescedFlushTask = nil
        guard active, ready, !sending, let webView, let payload = pending else { return }
        if let sent, pendingScroll == sentScroll, payload.isSameSessionRenderEquivalent(to: sent) {
            self.sent = payload
            return
        }
        guard payload != sent || pendingScroll != sentScroll else { return }
        let scroll = pendingScroll
        let requestChanged = scroll != sentScroll
        let tailPatch: ChatRenderSnapshot.Message? = (!requestChanged && didRender && sent != nil)
            ? Self.streamingTailPatch(from: sent!, to: payload)
            : nil
        let needsFullPayload = (tailPatch == nil && payload != sent)
        let document = documentID
        sending = true
        lastFlushTime = .now

        func sendToWeb(tailJSON: Any, payloadJSON: Any) {
            guard self.webView === webView, document == self.documentID else {
                self.sending = false
                return
            }
            let script = "if (tailJSON) MoMoChat.patchTailMessage(JSON.parse(tailJSON)); else if (payloadJSON) MoMoChat.render(JSON.parse(payloadJSON)); if (openChat) MoMoChat.openChat(); if (latest) MoMoChat.scrollToBottom();"
            webView.callAsyncJavaScript(script, arguments: [
                "tailJSON": tailJSON,
                "payloadJSON": payloadJSON,
                "openChat": requestChanged && (scroll?.destination == .entry || scroll?.destination == .resumeTab),
                "latest": requestChanged && scroll?.destination == .latest && payload.snapshot.focus == nil],
                in: nil, in: .page, completionHandler: { [weak self] result in
                guard let self, self.webView === webView, document == self.documentID else { return }
                self.sending = false
                switch result {
                case .success:
                    self.reloads = 0
                    self.sent = payload
                    self.sentScroll = scroll
                    if !self.didRender, !payload.snapshot.messages.isEmpty,
                       payload.snapshot.sessionID == self.pending?.snapshot.sessionID {
                        self.didRender = true; self.rendered()
                    }
                    self.scheduleFlush()
                case .failure(let error): self.recover(from: error)
                }
            })
        }

        if needsFullPayload && payload.snapshot.messages.count > 20 {
            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                    await MainActor.run {
                        sendToWeb(tailJSON: NSNull(), payloadJSON: encoded)
                    }
                } catch {
                    await MainActor.run {
                        self?.sending = false
                        self?.recover(from: error)
                    }
                }
            }
        } else {
            do {
                let tailJSON: Any = try tailPatch.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? NSNull()
                let payloadJSON: Any = needsFullPayload
                    ? String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
                    : NSNull()
                sendToWeb(tailJSON: tailJSON, payloadJSON: payloadJSON)
            } catch {
                sending = false
                recover(from: error)
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": ready = true; flush()
        case "retryMessage":
            if let value = body["value"] as? [String: String], let raw = value["turnID"], let id = UUID(uuidString: raw),
               let snapshot = pending?.snapshot, value["sessionID"] == snapshot.sessionID,
               snapshot.messages.contains(where: { $0.role == "user" && $0.turnID == raw && $0.delivery == "failed" }) {
                retryMessage(id)
            }
        case "regenerate":
            if let value = body["value"] as? [String: String] { requestRegeneration(value) }
        case "attachment":
            if let value = body["value"] as? [String: String], let raw = value["attachmentID"], let id = UUID(uuidString: raw),
               let snapshot = pending?.snapshot, value["sessionID"] == snapshot.sessionID,
               snapshot.messages.flatMap(\.blocks).contains(where: { $0.type == "attachment" && $0.attachmentID == raw }) {
                attachment(id)
            }
        case "systemAction":
            if let value = body["value"] as? [String: String], let raw = value["actionID"], let id = UUID(uuidString: raw),
               let snapshot = pending?.snapshot, value["sessionID"] == snapshot.sessionID,
               snapshot.messages.flatMap(\.blocks).contains(where: { block in
                   guard let output = block.tool?.output, let data = output.data(using: .utf8),
                         let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                   return (receipt["actionID"] as? String).flatMap(UUID.init(uuidString:)) == id
               }) { systemAction(id) }
        case "readingPosition":
            if let value = body["value"] as? [String: Any] { receiveReadingPosition(value) }
        case "bubbleRegions":
            if let list = body["value"] as? [[String: Any]] { receiveBubbleRegions(list) }
        case "pressedBubble":
            if let dict = body["value"] as? [String: Any] { receivePressedBubble(dict) }
        case "selectionCleared":
            #if os(iOS)
            activeSelectingBubbleID = nil
            #endif
        case "copy": if let text = body["value"] as? String {
            Self.copyTextToPasteboard(text)
        }
        case "link":
            if let text = body["value"] as? String, let url = URL(string: text) {
                // Source/version authorization is still performed by RecordingSourceLinks.
                switch url.scheme?.lowercased() {
                case "https", "http": if url.host != nil { open(url) }
                case "momoagent": if url.host == "source" || url.host == "memory" { open(url) }
                default: break
                }
            }
        default: break
        }
    }

    func receiveReadingPosition(_ value: [String: Any]) {
        guard active, let rawID = value["sessionID"] as? String, let id = UUID(uuidString: rawID),
              let snapshot = [pending?.snapshot, sent?.snapshot].compactMap({ $0 }).first(where: { $0.sessionID == rawID }),
              let following = value["following"] as? Bool,
              let top = value["top"] as? Double, let offset = value["anchorOffset"] as? Double else { return }
        let anchorID = value["anchorID"] as? String
        let visibleIDs = Set(snapshot.messages.map { $0.role == "assistant" ? "\($0.id):reply" : $0.id })
        if let anchorID, !visibleIDs.contains(anchorID) { return }
        var position = ChatReadingPosition(sessionID: id, following: following, top: top,
                                           anchorID: anchorID, anchorOffset: offset)
        let shown = value["visibleMessageIDs"] as? [String] ?? []
        let known = Set(snapshot.messages.map(\.id))
        guard shown.count <= 500, shown.allSatisfy({ known.contains($0) }) else { return }
        position.visibleMessageIDs = shown
        guard position.isValid else { return }
        readingPosition(position)
    }

    func requestRegeneration(_ value: [String: String]) {
        guard let snapshot = pending?.snapshot, !snapshot.busy,
              value["sessionID"] == snapshot.sessionID, let id = value["messageID"],
              snapshot.messages.contains(where: { $0.id == id && $0.role == "assistant" && $0.state != "streaming" }) else { return }
        regenerate(id)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let localDocument = url?.isFileURL == true && url?.deletingLastPathComponent() == resourceDirectory
        decisionHandler(localDocument && navigationAction.navigationType == .other ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if let recoveryNavigation, let navigation, navigation !== recoveryNavigation { return }
        recover(from: error)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if let recoveryNavigation, let navigation, navigation !== recoveryNavigation { return }
        recover(from: error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { recover(from: WKError(.webContentProcessTerminated)) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let recoveryNavigation, let navigation, navigation !== recoveryNavigation { return }
        let document = documentID
        webView.evaluateJavaScript("typeof window.MoMoChat === 'object'", completionHandler: { [weak self] value, error in
            guard let self, self.webView === webView, self.documentID == document else { return }
            if error != nil || value as? Bool != true { recover(from: error ?? WKError(.javaScriptExceptionOccurred)) }
        })
    }

    static func copyTextToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func receiveBubbleRegions(_ raw: [[String: Any]]) {
        func rect(_ dict: [String: Any], xKey: String, yKey: String) -> CGRect? {
            guard let x = dict[xKey] as? Double, let y = dict[yKey] as? Double,
                  let w = dict["width"] as? Double, let h = dict["height"] as? Double,
                  w > 0, h > 0 else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        bubbleRegions = raw.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let copyText = item["copyText"] as? String, !copyText.isEmpty,
                  let docRect = rect(item, xKey: "x", yKey: "y"),
                  let vpRect = rect(item, xKey: "vpX", yKey: "vpY") else { return nil }
            let codeBlocks: [ChatBubbleRegion.CodeBlock] = ((item["codeBlocks"] as? [[String: Any]]) ?? []).compactMap { cb in
                guard let text = cb["text"] as? String, !text.isEmpty,
                      let cDoc = rect(cb, xKey: "x", yKey: "y"),
                      let cVp = rect(cb, xKey: "vpX", yKey: "vpY") else { return nil }
                return .init(docRect: cDoc, viewportRect: cVp, text: text)
            }
            let linksRaw = (item["links"] as? [[String: Any]]) ?? []
            return ChatBubbleRegion(
                id: id,
                messageID: (item["messageID"] as? String) ?? "",
                isUser: (item["isUser"] as? Bool) ?? false,
                docRect: docRect,
                viewportRect: vpRect,
                copyText: copyText,
                codeBlocks: codeBlocks,
                interactiveDocRects: linksRaw.compactMap { rect($0, xKey: "x", yKey: "y") },
                interactiveViewportRects: linksRaw.compactMap { rect($0, xKey: "vpX", yKey: "vpY") }
            )
        }
    }

    private func receivePressedBubble(_ dict: [String: Any]) {
        let hit = (dict["hit"] as? Bool) ?? false
        pressedBubble = PressedBubbleState(
            hit: hit,
            id: (dict["id"] as? String) ?? "",
            messageID: (dict["messageID"] as? String) ?? "",
            isUser: (dict["isUser"] as? Bool) ?? false,
            isLink: (dict["isLink"] as? Bool) ?? false,
            docX: CGFloat((dict["docX"] as? Double) ?? 0),
            docY: CGFloat((dict["docY"] as? Double) ?? 0),
            dx: CGFloat((dict["dx"] as? Double) ?? 0),
            dy: CGFloat((dict["dy"] as? Double) ?? 0),
            width: CGFloat((dict["width"] as? Double) ?? 0),
            height: CGFloat((dict["height"] as? Double) ?? 0),
            copyText: (dict["copyText"] as? String) ?? "",
            codeText: (dict["codeText"] as? String) ?? "",
            selectedText: (dict["selectedText"] as? String) ?? "",
            timestamp: .now
        )
    }

    #if os(iOS)
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor (UIContextMenuConfiguration?) -> Void) {
        // Suppress WebKit's raw URL link preview inside chat bubbles so our native iMessage bubble context menu handles the turn cleanly.
        completionHandler(nil)
    }

    func resolveBubbleHit(at location: CGPoint, in webView: WKWebView) -> (id: String, messageID: String, isUser: Bool, rectInWebView: CGRect, copyText: String, codeText: String?)? {
        func handleActiveSelection(for hitID: String) -> Bool {
            guard let activeID = activeSelectingBubbleID else { return true }
            if activeID == hitID {
                return false
            }
            activeSelectingBubbleID = nil
            webView.evaluateJavaScript("if (window.MoMoChat?.clearBubbleSelection) window.MoMoChat.clearBubbleSelection();", completionHandler: nil)
            return true
        }
        let contentView = webView.scrollView.subviews.first { String(describing: type(of: $0)).contains("WKContentView") } ?? webView.scrollView.subviews.first
        if let pressed = pressedBubble, pressed.timestamp.duration(to: .now) < .milliseconds(700) {
            if pressed.hit {
                if pressed.isLink { return nil }
                let docRect = CGRect(x: pressed.docX, y: pressed.docY, width: pressed.width, height: pressed.height)
                let rect = contentView.map { webView.convert(docRect, from: $0) } ?? CGRect(x: location.x + pressed.dx, y: location.y + pressed.dy, width: pressed.width, height: pressed.height)
                if rect.width > 0, rect.height > 0, !pressed.copyText.isEmpty {
                    guard handleActiveSelection(for: pressed.id) else { return nil }
                    return (pressed.id, pressed.messageID, pressed.isUser, rect, pressed.copyText, pressed.codeText.isEmpty ? nil : pressed.codeText)
                }
            }
        }
        for region in bubbleRegions {
            let rectInWeb: CGRect = if let contentView {
                webView.convert(region.docRect, from: contentView)
            } else {
                region.viewportRect
            }
            guard rectInWeb.insetBy(dx: -4, dy: -4).contains(location) else { continue }
            for linkDoc in region.interactiveDocRects {
                let linkRect = contentView.map { webView.convert(linkDoc, from: $0) } ?? linkDoc
                if linkRect.insetBy(dx: -2, dy: -2).contains(location) { return nil }
            }
            var hitCode: String? = nil
            for cb in region.codeBlocks {
                let cbRect = contentView.map { webView.convert(cb.docRect, from: $0) } ?? cb.viewportRect
                if cbRect.contains(location) { hitCode = cb.text; break }
            }
            guard handleActiveSelection(for: region.id) else { return nil }
            return (region.id, region.messageID, region.isUser, rectInWeb, region.copyText, hitCode)
        }
        return nil
    }

    fileprivate func beginInPlaceBubbleSelection(_ id: String) {
        guard let webView,
              let idData = try? JSONEncoder().encode(id),
              let idJSON = String(data: idData, encoding: .utf8) else { return }
        activeSelectingBubbleID = id
        webView.evaluateJavaScript("window.MoMoChat?.beginBubbleSelection ? window.MoMoChat.beginBubbleSelection(\(idJSON)) : false") { [weak self, weak webView] result, _ in
            Task { @MainActor in
                guard let self, let webView, self.activeSelectingBubbleID == id, (result as? Bool) == true else {
                    self?.activeSelectingBubbleID = nil
                    return
                }
                let contentView = webView.scrollView.subviews.first { String(describing: type(of: $0)).contains("WKContentView") } ?? webView
                _ = contentView.becomeFirstResponder()
                contentView.selectAll(nil)
            }
        }
    }

    fileprivate func setDOMBubbleHidden(_ id: String, hidden: Bool, completion: (@MainActor () -> Void)? = nil) {
        guard let webView,
              let idData = try? JSONEncoder().encode(id),
              let idJSON = String(data: idData, encoding: .utf8) else {
            completion?()
            return
        }
        let flag = hidden ? "true" : "false"
        webView.evaluateJavaScript("if (window.MoMoChat?.setBubbleHidden) window.MoMoChat.setBubbleHidden(\(idJSON), \(flag));") { _, _ in
            Task { @MainActor in completion?() }
        }
    }
    #else
    fileprivate func configureMacContextMenu(_ menu: NSMenu, with event: NSEvent, in webView: WKWebView) {
        menu.items.removeAll { item in
            guard let raw = item.identifier?.rawValue else { return false }
            return raw.contains("Reload") || raw.contains("GoBack") || raw.contains("GoForward") || raw.contains("OpenLink") || raw.contains("Download")
        }
        let hasNativeSelectionCopy = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        let local = webView.convert(event.locationInWindow, from: nil)
        let vpPoint = CGPoint(x: local.x, y: webView.isFlipped ? local.y : webView.bounds.height - local.y)

        var copyText: String? = nil
        var codeText: String? = nil
        if let pressed = pressedBubble, pressed.timestamp.duration(to: .now) < .milliseconds(700), pressed.hit, !pressed.copyText.isEmpty {
            copyText = pressed.copyText
            codeText = pressed.codeText.isEmpty ? nil : pressed.codeText
        } else if let region = bubbleRegions.first(where: { $0.viewportRect.insetBy(dx: -4, dy: -4).contains(vpPoint) }) {
            copyText = region.copyText
            codeText = region.codeBlocks.first(where: { $0.viewportRect.contains(vpPoint) })?.text
        }

        if hasNativeSelectionCopy {
            if let copyText {
                pendingMacCopyText = copyText
                menu.addItem(.separator())
                let fullItem = NSMenuItem(title: String(localized: "拷贝整条消息", bundle: AppLanguage.resourceBundle),
                                          action: #selector(copyMacFullMessage(_:)), keyEquivalent: "")
                fullItem.target = self
                fullItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                menu.addItem(fullItem)
            }
            return
        }

        menu.removeAllItems()
        guard let copyText else { return }
        pendingMacCopyText = copyText
        let copyItem = NSMenuItem(title: String(localized: "拷贝", bundle: AppLanguage.resourceBundle),
                                  action: #selector(copyMacFullMessage(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copyItem)

        if let codeText {
            pendingMacCodeText = codeText
            let codeItem = NSMenuItem(title: String(localized: "拷贝代码", bundle: AppLanguage.resourceBundle),
                                      action: #selector(copyMacCodeBlock(_:)), keyEquivalent: "")
            codeItem.target = self
            codeItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            menu.addItem(codeItem)
        }
    }

    @objc private func copyMacFullMessage(_ sender: Any?) {
        if let text = pendingMacCopyText { Self.copyTextToPasteboard(text) }
    }

    @objc private func copyMacCodeBlock(_ sender: Any?) {
        if let code = pendingMacCodeText { Self.copyTextToPasteboard(code) }
    }
    #endif
}

#if os(iOS)
extension ChatWebCoordinator: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let webView, let hit = resolveBubbleHit(at: location, in: webView) else { return nil }
        activePreviewHost?.removeFromSuperview()
        activePreviewHost = nil
        activeContextBubbleID = hit.id
        activeContextBubbleRect = hit.rectInWebView

        let hitID = hit.id
        let copyText = hit.copyText
        let codeText = hit.codeText
        let messageID = hit.messageID
        let canRegenerate = (pending?.snapshot.canRegenerate == true) && (pending?.snapshot.busy == false) && !hit.isUser && !messageID.isEmpty

        return UIContextMenuConfiguration(identifier: hitID as NSString, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = [
                UIAction(title: String(localized: "拷贝", bundle: AppLanguage.resourceBundle),
                         image: UIImage(systemName: "doc.on.doc")) { _ in
                    ChatWebCoordinator.copyTextToPasteboard(copyText)
                }
            ]
            if let codeText, !codeText.isEmpty {
                actions.append(
                    UIAction(title: String(localized: "拷贝代码", bundle: AppLanguage.resourceBundle),
                             image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { _ in
                        ChatWebCoordinator.copyTextToPasteboard(codeText)
                    }
                )
            }
            actions.append(
                UIAction(title: String(localized: "选择文本", bundle: AppLanguage.resourceBundle),
                         image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
                    self?.pendingInPlaceSelectBubbleID = hitID
                }
            )
            if canRegenerate {
                actions.append(
                    UIAction(title: String(localized: "重新生成回复", bundle: AppLanguage.resourceBundle),
                             image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                        guard let self, let sessionID = self.pending?.snapshot.sessionID else { return }
                        self.requestRegeneration(["sessionID": sessionID, "messageID": messageID])
                    }
                )
            }
            return UIMenu(title: "", children: actions)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let webView,
              let bubbleRect = activeContextBubbleRect,
              let bubbleID = activeContextBubbleID else { return nil }
        let visibleRect = bubbleRect.intersection(webView.bounds)
        guard visibleRect.width >= 16, visibleRect.height >= 16,
              let snapshot = webView.resizableSnapshotView(from: visibleRect, afterScreenUpdates: false, withCapInsets: .zero) else {
            return nil
        }
        let host = UIView(frame: visibleRect)
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        snapshot.frame = host.bounds
        host.addSubview(snapshot)
        webView.addSubview(host)
        activePreviewHost = host
        setDOMBubbleHidden(bubbleID, hidden: true)

        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let path = UIBezierPath(roundedRect: host.bounds, cornerRadius: 18)
        parameters.visiblePath = path
        parameters.shadowPath = path
        return UITargetedPreview(view: host, parameters: parameters)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview? {
        guard let host = activePreviewHost, host.superview != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        let path = UIBezierPath(roundedRect: host.bounds, cornerRadius: 18)
        parameters.visiblePath = path
        parameters.shadowPath = path
        return UITargetedPreview(view: host, parameters: parameters)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        let host = activePreviewHost
        let bubbleID = activeContextBubbleID
        let selectBubbleID = pendingInPlaceSelectBubbleID
        activePreviewHost = nil
        activeContextBubbleID = nil
        activeContextBubbleRect = nil
        pendingInPlaceSelectBubbleID = nil

        let cleanup: @MainActor () -> Void = { [weak self] in
            if let bubbleID, let self {
                self.setDOMBubbleHidden(bubbleID, hidden: false) {
                    host?.removeFromSuperview()
                    if let selectBubbleID {
                        self.beginInPlaceBubbleSelection(selectBubbleID)
                    }
                }
            } else {
                host?.removeFromSuperview()
                if let selectBubbleID {
                    self?.beginInPlaceBubbleSelection(selectBubbleID)
                }
            }
        }
        if let animator {
            animator.addCompletion { MainActor.assumeIsolated { cleanup() } }
        } else {
            cleanup()
        }
    }
}
#endif
