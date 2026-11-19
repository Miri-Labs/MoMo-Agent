import SwiftUI
import WebKit
import OSLog
import MoMoContracts
#if os(iOS)
import UIKit.UIGestureRecognizerSubclass
#endif

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
    var onQuickReply: (String) -> Void = { _ in }
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
                        readingPosition: onReadingPosition, systemAction: onSystemAction, attachment: onAttachment, retryMessage: onRetryMessage, quickReply: onQuickReply)
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
    let quickReply: (String) -> Void

    func makeCoordinator() -> ChatWebCoordinator {
        let coordinator = ChatWebCoordinator(failed: failed, open: open, regenerate: regenerate, readingPosition: readingPosition, systemAction: systemAction)
        coordinator.rendered = rendered
        coordinator.recovering = recovering
        coordinator.setActive(active)
        coordinator.attachment = attachment
        coordinator.retryMessage = retryMessage
        coordinator.quickReply = quickReply
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
        context.coordinator.quickReply = quickReply
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
        coordinator.dismissActiveBubbleSelection(animated: false)
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
        guard activeBubbleSelectionView == nil else { return }
        let delta = gesture.translation(in: webView)
        if delta.y > 12, delta.y > abs(delta.x) { webView?.window?.endEditing(true) }
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard activeBubbleSelectionView == nil else { return false }
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
    var quickReply: (String) -> Void = { _ in }
    var rendered: () -> Void = {}
    var recovering: () -> Void = {}
    var bubbleRegions: [ChatBubbleRegion] = []
    fileprivate var pressedBubble: PressedBubbleState?
    #if os(iOS)
    weak var contextMenuInteraction: UIContextMenuInteraction?
    fileprivate weak var activePreviewHost: UIView?
    fileprivate var activeContextBubbleID: String?
    fileprivate var activeContextBubbleRect: CGRect?
    fileprivate weak var activeBubbleSelectionView: TelegramBubbleSelectionView?
    fileprivate var cachedSelectionRawLayout: RawExtractedBubbleLayout?
    fileprivate var selectionPrefetchGeneration = 0
    fileprivate var pendingSelectionRequest: PendingBubbleSelectionRequest?
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
        #if os(iOS)
        if let sent, (sent.snapshot.sessionID != payload.snapshot.sessionID || sent.appearance != payload.appearance) {
            dismissActiveBubbleSelection(animated: false)
            cachedSelectionRawLayout = nil
        }
        #endif
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
            #if os(iOS)
            dismissActiveBubbleSelection(animated: false)
            #endif
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
        #if os(iOS)
        dismissActiveBubbleSelection(animated: false)
        cachedSelectionRawLayout = nil
        #endif
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
        case "copy": if let text = body["value"] as? String {
            Self.copyTextToPasteboard(text)
        }
        case "quickReply":
            if let value = body["value"] as? [String: String],
               let rawText = value["text"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawText.isEmpty, rawText.count <= 2000,
               let snapshot = pending?.snapshot ?? sent?.snapshot,
               value["sessionID"] == snapshot.sessionID {
                quickReply(rawText)
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
        guard activeBubbleSelectionView == nil else { return nil }
        let contentView = Self.findWKContentView(in: webView)
        if let pressed = pressedBubble, pressed.timestamp.duration(to: .now) < .milliseconds(700) {
            if pressed.hit {
                if pressed.isLink { return nil }
                let docRect = CGRect(x: pressed.docX, y: pressed.docY, width: pressed.width, height: pressed.height)
                let rect = contentView.map { webView.convert(docRect, from: $0) } ?? CGRect(x: location.x + pressed.dx, y: location.y + pressed.dy, width: pressed.width, height: pressed.height)
                if rect.width > 0, rect.height > 0, !pressed.copyText.isEmpty {
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
            return (region.id, region.messageID, region.isUser, rectInWeb, region.copyText, hitCode)
        }
        return nil
    }

    static func findWKContentView(in webView: WKWebView) -> UIView? {
        webView.scrollView.subviews.first { String(describing: type(of: $0)).contains("WKContentView") }
            ?? webView.scrollView.subviews.first
    }

    fileprivate func dismissActiveBubbleSelection(animated: Bool) {
        selectionPrefetchGeneration &+= 1
        guard let view = activeBubbleSelectionView else { return }
        activeBubbleSelectionView = nil
        view.dismissSelection(animated: animated)
    }

    fileprivate func prefetchBubbleSelectionLayout(_ id: String) {
        if cachedSelectionRawLayout?.id == id { return }
        fetchBubbleSelectionLayout(id) { [weak self] raw in
            guard let self, let raw else { return }
            self.cachedSelectionRawLayout = raw
        }
    }

    fileprivate func fetchBubbleSelectionLayout(_ id: String, completion: @escaping @MainActor (RawExtractedBubbleLayout?) -> Void) {
        guard let webView,
              let idData = try? JSONEncoder().encode(id),
              let idJSON = String(data: idData, encoding: .utf8) else {
            completion(nil)
            return
        }
        let doc = documentID
        webView.evaluateJavaScript("window.MoMoChat?.extractBubbleSelectionLayout ? window.MoMoChat.extractBubbleSelectionLayout(\(idJSON)) : null") { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.webView === webView, self.documentID == doc,
                      let dict = result as? [String: Any],
                      let parsed = RawExtractedBubbleLayout.parse(dict) else {
                    completion(nil)
                    return
                }
                completion(parsed)
            }
        }
    }

    fileprivate func activateBubbleSelection(_ request: PendingBubbleSelectionRequest) {
        dismissActiveBubbleSelection(animated: false)
        if let cached = cachedSelectionRawLayout, cached.id == request.id {
            mountBubbleSelection(raw: cached, request: request)
            return
        }
        let gen = selectionPrefetchGeneration
        fetchBubbleSelectionLayout(request.id) { [weak self] raw in
            guard let self, self.selectionPrefetchGeneration == gen, let raw else { return }
            self.cachedSelectionRawLayout = raw
            self.mountBubbleSelection(raw: raw, request: request)
        }
    }

    private func mountBubbleSelection(raw: RawExtractedBubbleLayout, request: PendingBubbleSelectionRequest) {
        guard let webView else { return }
        let scrollView = webView.scrollView
        let contentView = Self.findWKContentView(in: webView)
        let originOffset = contentView.map { scrollView.convert(CGPoint.zero, from: $0) } ?? .zero
        let layout = ExtractedBubbleSelectionLayout.build(from: raw, originOffset: originOffset)
        guard !layout.lines.isEmpty, layout.nsText.length > 0 else { return }

        let dark = pending?.appearance.dark ?? (webView.traitCollection.userInterfaceStyle == .dark)
        let headerInset = pending?.appearance.headerInset ?? 0
        let pressInScroll = scrollView.convert(request.pressLocationInWebView, from: webView)
        let contentW = max(scrollView.contentSize.width, webView.bounds.width)
        let contentH = max(scrollView.contentSize.height, webView.bounds.height + 200)

        let overlay = TelegramBubbleSelectionView(
            frame: CGRect(x: 0, y: 0, width: contentW, height: contentH),
            webView: webView,
            layout: layout,
            pressLocationInScroll: pressInScroll,
            dark: dark,
            headerInset: headerInset,
            reduceMotion: pending?.appearance.reduceMotion ?? false,
            onDismiss: { [weak self] animated in
                self?.dismissActiveBubbleSelection(animated: animated)
            }
        )
        scrollView.addSubview(overlay)
        activeBubbleSelectionView = overlay
        overlay.presentSelectionInPlace()
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
        dismissActiveBubbleSelection(animated: false)
        activePreviewHost?.removeFromSuperview()
        activePreviewHost = nil
        activeContextBubbleID = hit.id
        activeContextBubbleRect = hit.rectInWebView
        pendingSelectionRequest = nil

        let hitID = hit.id
        let isUser = hit.isUser
        let copyText = hit.copyText
        let codeText = hit.codeText
        let messageID = hit.messageID
        let canRegenerate = (pending?.snapshot.canRegenerate == true) && (pending?.snapshot.busy == false) && !hit.isUser && !messageID.isEmpty

        // Pre-warm exact DOM glyph boxes while the user inspects the context menu so tapping "选择文本" activates in <1ms.
        prefetchBubbleSelectionLayout(hitID)

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
                    guard let self else { return }
                    let req = PendingBubbleSelectionRequest(
                        id: hitID,
                        isUser: isUser,
                        pressLocationInWebView: location
                    )
                    self.pendingSelectionRequest = req
                    self.setDOMBubbleHidden(hitID, hidden: false)
                    self.activateBubbleSelection(req)
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
        if pendingSelectionRequest != nil {
            return nil
        }
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
        let hadSelectionRequest = (pendingSelectionRequest != nil)
        activePreviewHost = nil
        activeContextBubbleID = nil
        activeContextBubbleRect = nil
        pendingSelectionRequest = nil

        if hadSelectionRequest {
            host?.removeFromSuperview()
            if let bubbleID {
                setDOMBubbleHidden(bubbleID, hidden: false)
            }
            if let animator {
                animator.addCompletion { [weak self] in
                    MainActor.assumeIsolated {
                        self?.activeBubbleSelectionView?.ensureEditMenuPresented()
                    }
                }
            } else {
                activeBubbleSelectionView?.ensureEditMenuPresented()
            }
            return
        }

        let cleanup: @MainActor () -> Void = { [weak self] in
            if let bubbleID, let self {
                self.setDOMBubbleHidden(bubbleID, hidden: false) {
                    host?.removeFromSuperview()
                }
            } else {
                host?.removeFromSuperview()
            }
        }
        if let animator {
            animator.addCompletion { MainActor.assumeIsolated { cleanup() } }
        } else {
            cleanup()
        }
    }
}

fileprivate struct PendingBubbleSelectionRequest: Sendable {
    let id: String
    let isUser: Bool
    let pressLocationInWebView: CGPoint
}

fileprivate struct RawExtractedBubbleLayout: Sendable {
    struct RawBox: Sendable {
        let startUTF16: Int
        let endUTF16: Int
        let docX: CGFloat
        let docY: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    let id: String
    let isUser: Bool
    let docRect: CGRect
    let text: String
    let boxes: [RawBox]

    static func parse(_ dict: [String: Any]) -> RawExtractedBubbleLayout? {
        guard let id = dict["id"] as? String, !id.isEmpty,
              let text = dict["text"] as? String, !text.isEmpty else { return nil }
        let rawNumbers: [NSNumber]? = (dict["boxes"] as? [NSNumber])
            ?? (dict["boxes"] as? [Any])?.compactMap { $0 as? NSNumber }
        guard let rawNumbers, rawNumbers.count >= 6 else { return nil }

        let isUser = (dict["isUser"] as? Bool) ?? false
        let docX = CGFloat((dict["docX"] as? NSNumber)?.doubleValue ?? 0)
        let docY = CGFloat((dict["docY"] as? NSNumber)?.doubleValue ?? 0)
        let width = CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? 0)
        let height = CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? 0)
        let utf16Len = (text as NSString).length

        var boxes: [RawBox] = []
        boxes.reserveCapacity(rawNumbers.count / 6)
        var i = 0
        while i + 5 < rawNumbers.count {
            let s = max(0, min(utf16Len, rawNumbers[i].intValue))
            let e = max(s, min(utf16Len, rawNumbers[i + 1].intValue))
            let x = CGFloat(rawNumbers[i + 2].doubleValue)
            let y = CGFloat(rawNumbers[i + 3].doubleValue)
            let w = CGFloat(rawNumbers[i + 4].doubleValue)
            let h = CGFloat(rawNumbers[i + 5].doubleValue)
            if e > s, w > 0, h > 0 {
                boxes.append(RawBox(startUTF16: s, endUTF16: e, docX: x, docY: y, width: w, height: h))
            }
            i += 6
        }
        guard !boxes.isEmpty else { return nil }
        return RawExtractedBubbleLayout(
            id: id,
            isUser: isUser,
            docRect: CGRect(x: docX, y: docY, width: width, height: height),
            text: text,
            boxes: boxes
        )
    }
}

fileprivate struct ExtractedBubbleSelectionLayout {
    struct GlyphBox {
        let startUTF16: Int
        let endUTF16: Int
        let rect: CGRect

        func slicedRect(for selected: NSRange) -> CGRect? {
            let s = max(startUTF16, selected.location)
            let e = min(endUTF16, NSMaxRange(selected))
            guard e > s else { return nil }
            let total = endUTF16 - startUTF16
            guard total > 1, (s > startUTF16 || e < endUTF16) else { return rect }
            let f0 = CGFloat(s - startUTF16) / CGFloat(total)
            let f1 = CGFloat(e - startUTF16) / CGFloat(total)
            return CGRect(
                x: rect.minX + rect.width * f0,
                y: rect.minY,
                width: max(2, rect.width * (f1 - f0)),
                height: rect.height
            )
        }
    }

    struct SelectionLine {
        var rect: CGRect
        var glyphs: [GlyphBox]
    }

    let id: String
    let isUser: Bool
    let bubbleRect: CGRect
    let text: String
    let nsText: NSString
    let glyphs: [GlyphBox]
    let lines: [SelectionLine]

    static func build(from raw: RawExtractedBubbleLayout, originOffset: CGPoint) -> ExtractedBubbleSelectionLayout {
        let bubbleRect = raw.docRect.offsetBy(dx: originOffset.x, dy: originOffset.y)
        let glyphs: [GlyphBox] = raw.boxes.map { box in
            GlyphBox(
                startUTF16: box.startUTF16,
                endUTF16: box.endUTF16,
                rect: CGRect(
                    x: box.docX + originOffset.x,
                    y: box.docY + originOffset.y,
                    width: box.width,
                    height: box.height
                )
            )
        }

        var lines: [SelectionLine] = []
        for glyph in glyphs {
            if let lastIdx = lines.indices.last,
               abs(glyph.rect.midY - lines[lastIdx].rect.midY) <= max(glyph.rect.height, lines[lastIdx].rect.height) * 0.45 {
                lines[lastIdx].rect = lines[lastIdx].rect.union(glyph.rect)
                lines[lastIdx].glyphs.append(glyph)
            } else {
                lines.append(SelectionLine(rect: glyph.rect, glyphs: [glyph]))
            }
        }
        for idx in lines.indices {
            lines[idx].glyphs.sort { $0.rect.minX < $1.rect.minX }
        }
        lines.sort { $0.rect.midY < $1.rect.midY }

        return ExtractedBubbleSelectionLayout(
            id: raw.id,
            isUser: raw.isUser,
            bubbleRect: bubbleRect,
            text: raw.text,
            nsText: raw.text as NSString,
            glyphs: glyphs,
            lines: lines
        )
    }

    func characterIndex(at point: CGPoint) -> Int {
        let total = nsText.length
        guard total > 0, let firstLine = lines.first, let lastLine = lines.last else { return 0 }
        if point.y < firstLine.rect.minY - 10 { return 0 }
        if point.y > lastLine.rect.maxY + 10 { return total }

        var candidateIndices: [Int] = []
        for idx in lines.indices {
            let lineRect = lines[idx].rect
            if point.y >= lineRect.minY - 4 && point.y <= lineRect.maxY + 4 {
                candidateIndices.append(idx)
            }
        }

        let chosenLineIndex: Int
        if candidateIndices.count == 1 {
            chosenLineIndex = candidateIndices[0]
        } else if candidateIndices.count > 1 {
            chosenLineIndex = candidateIndices.min { a, b in
                horizontalDistance(to: lines[a].rect, x: point.x) < horizontalDistance(to: lines[b].rect, x: point.x)
            } ?? candidateIndices[0]
        } else {
            chosenLineIndex = lines.indices.min { a, b in
                verticalDistance(to: lines[a].rect, y: point.y) < verticalDistance(to: lines[b].rect, y: point.y)
            } ?? 0
        }

        let line = lines[chosenLineIndex]
        guard let firstGlyph = line.glyphs.first, let lastGlyph = line.glyphs.last else { return 0 }
        if point.x <= firstGlyph.rect.minX {
            return firstGlyph.startUTF16
        }
        if point.x >= lastGlyph.rect.maxX {
            return lastGlyph.endUTF16
        }
        for glyph in line.glyphs {
            if point.x <= glyph.rect.maxX {
                let count = glyph.endUTF16 - glyph.startUTF16
                if count > 1, glyph.rect.width > 1 {
                    let frac = min(1, max(0, (point.x - glyph.rect.minX) / glyph.rect.width))
                    let offset = Int(round(frac * CGFloat(count)))
                    return min(glyph.endUTF16, max(glyph.startUTF16, glyph.startUTF16 + offset))
                }
                return point.x < glyph.rect.midX ? glyph.startUTF16 : glyph.endUTF16
            }
        }
        return lastGlyph.endUTF16
    }

    private func horizontalDistance(to rect: CGRect, x: CGFloat) -> CGFloat {
        if x < rect.minX { return rect.minX - x }
        if x > rect.maxX { return x - rect.maxX }
        return 0
    }

    private func verticalDistance(to rect: CGRect, y: CGFloat) -> CGFloat {
        if y < rect.minY { return rect.minY - y }
        if y > rect.maxY { return y - rect.maxY }
        return 0
    }
}

@MainActor
fileprivate final class SelectionDisplayLinkTarget: NSObject {
    weak var owner: TelegramBubbleSelectionView?
    @objc func step(_ link: CADisplayLink) {
        owner?.handleAutoScrollStep(link)
    }
}

@MainActor
fileprivate final class SelectionKnobView: UIView {
    let isLeading: Bool
    private let stemLayer = CALayer()
    private let dotLayer = CALayer()

    init(isLeading: Bool) {
        self.isLeading = isLeading
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityIdentifier = isLeading ? "assistant.selectionKnob.leading" : "assistant.selectionKnob.trailing"

        let blue = UIColor.systemBlue.cgColor
        stemLayer.backgroundColor = blue
        stemLayer.cornerRadius = 1.0

        dotLayer.backgroundColor = blue
        dotLayer.cornerRadius = 5.25
        dotLayer.shadowColor = UIColor.black.cgColor
        dotLayer.shadowOpacity = 0.20
        dotLayer.shadowRadius = 2.0
        dotLayer.shadowOffset = CGSize(width: 0, height: 1)

        layer.addSublayer(stemLayer)
        layer.addSublayer(dotLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updatePlacement(stemX: CGFloat, topY: CGFloat, bottomY: CGFloat) {
        let stemH = max(14, bottomY - topY)
        let dotDiameter: CGFloat = 10.5
        let dotRadius = dotDiameter * 0.5
        let viewW: CGFloat = 44
        let viewH = max(44, stemH + 28)
        let centerY: CGFloat = isLeading
            ? (topY - dotRadius + bottomY) * 0.5 - 2
            : (topY + bottomY + dotRadius) * 0.5 + 2
        frame = CGRect(
            x: round((stemX - viewW * 0.5) * 2) / 2,
            y: round((centerY - viewH * 0.5) * 2) / 2,
            width: viewW,
            height: viewH
        )

        let localX = stemX - frame.minX
        let localTop = topY - frame.minY
        let localBottom = localTop + stemH
        stemLayer.frame = CGRect(x: localX - 1.0, y: localTop, width: 2.0, height: stemH)
        if isLeading {
            dotLayer.frame = CGRect(
                x: localX - dotRadius,
                y: localTop - dotDiameter + 1.5,
                width: dotDiameter,
                height: dotDiameter
            )
        } else {
            dotLayer.frame = CGRect(
                x: localX - dotRadius,
                y: localBottom - 1.5,
                width: dotDiameter,
                height: dotDiameter
            )
        }
        let color = UIColor.systemBlue.resolvedColor(with: traitCollection).cgColor
        stemLayer.backgroundColor = color
        dotLayer.backgroundColor = color
    }
}

@MainActor
fileprivate final class TelegramKnobGestureRecognizer: UIGestureRecognizer {
    var hitTestKnob: ((CGPoint) -> Bool)?
    var onBegin: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: (() -> Void)?
    private weak var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard trackedTouch == nil, let touch = touches.first, let view else {
            if trackedTouch == nil { state = .failed }
            return
        }
        let pt = touch.location(in: view)
        guard hitTestKnob?(pt) == true else {
            state = .failed
            return
        }
        trackedTouch = touch
        state = .began
        onBegin?(pt)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch), let view else { return }
        state = .changed
        onMove?(trackedTouch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        self.trackedTouch = nil
        state = .ended
        onEnd?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        self.trackedTouch = nil
        state = .cancelled
        onEnd?()
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}

/// Telegram-iOS `TextSelectionNode` inspired in-place bubble text selection overlay.
/// Keeps the rendered HTML/CSS bubble 100% untouched (zero typography/spacing reflow) and draws
/// unified selection highlights + zero-hysteresis draggable lollipop grabber knobs directly in `webView.scrollView`.
@MainActor
fileprivate final class TelegramBubbleSelectionView: UIView, @MainActor UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    private enum DraggedKnob { case leading, trailing }

    private weak var webView: WKWebView?
    private let layout: ExtractedBubbleSelectionLayout
    private let dark: Bool
    private let headerInset: CGFloat
    private let reduceMotion: Bool
    private let onDismiss: (Bool) -> Void

    private let highlightLayer = CAShapeLayer()
    private let bubbleTargetView = UIView()
    private let leadingKnob = SelectionKnobView(isLeading: true)
    private let trailingKnob = SelectionKnobView(isLeading: false)

    private var editMenuInteraction: UIEditMenuInteraction?
    private var knobGesture: TelegramKnobGestureRecognizer?
    private var doubleTapGesture: UITapGestureRecognizer?
    private var singleTapGesture: UITapGestureRecognizer?

    private(set) var selectedRange: NSRange = NSRange(location: 0, length: 0)
    private var selectionMenuRect: CGRect = .zero
    private var leadingAnchorTextPoint: CGPoint = .zero
    private var trailingAnchorTextPoint: CGPoint = .zero

    private var activeDraggedKnob: DraggedKnob?
    private var fixedAnchorIndex: Int = 0
    private var dragTouchOffset: CGPoint = .zero
    private var lastTouchInWebView: CGPoint = .zero
    private var autoScrollSpeed: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var isDismissing = false

    init(
        frame: CGRect,
        webView: WKWebView,
        layout: ExtractedBubbleSelectionLayout,
        pressLocationInScroll: CGPoint,
        dark: Bool,
        headerInset: CGFloat,
        reduceMotion: Bool,
        onDismiss: @escaping (Bool) -> Void
    ) {
        self.webView = webView
        self.layout = layout
        self.dark = dark
        self.headerInset = headerInset
        self.reduceMotion = reduceMotion
        self.onDismiss = onDismiss
        super.init(frame: frame)

        overrideUserInterfaceStyle = dark ? .dark : .light
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityIdentifier = "assistant.bubbleSelectionOverlay"

        let isDarkSurface = dark || layout.isUser
        let baseTint = isDarkSurface
            ? UIColor(red: 0.24, green: 0.60, blue: 1.0, alpha: 1.0)
            : UIColor(red: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)
        highlightLayer.fillColor = baseTint.cgColor
        highlightLayer.opacity = isDarkSurface ? 0.36 : 0.22
        layer.addSublayer(highlightLayer)

        bubbleTargetView.frame = layout.bubbleRect
        bubbleTargetView.backgroundColor = .clear
        bubbleTargetView.isUserInteractionEnabled = false
        bubbleTargetView.isAccessibilityElement = true
        bubbleTargetView.accessibilityIdentifier = "assistant.bubbleSelectionTargetRect"
        addSubview(bubbleTargetView)

        addSubview(leadingKnob)
        addSubview(trailingKnob)

        let editMenu = UIEditMenuInteraction(delegate: self)
        addInteraction(editMenu)
        self.editMenuInteraction = editMenu

        setupGestures()
        selectedRange = Self.computeInitialRange(layout: layout, pressPoint: pressLocationInScroll)
        updateSelectionVisuals()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isDismissing else { return false }
        if leadingKnob.frame.insetBy(dx: -12, dy: -12).contains(point) ||
           trailingKnob.frame.insetBy(dx: -12, dy: -12).contains(point) {
            return true
        }
        if let webView {
            let inWeb = convert(point, to: webView)
            return webView.bounds.contains(inWeb)
        }
        return super.point(inside: point, with: event)
    }

    private func setupGestures() {
        let knob = TelegramKnobGestureRecognizer()
        knob.cancelsTouchesInView = true
        knob.delaysTouchesBegan = false
        knob.delaysTouchesEnded = false
        knob.hitTestKnob = { [weak self] pt in
            self?.knobSide(at: pt) != nil
        }
        knob.onBegin = { [weak self] pt in
            self?.beginKnobDrag(at: pt)
        }
        knob.onMove = { [weak self] pt in
            self?.continueKnobDrag(at: pt)
        }
        knob.onEnd = { [weak self] in
            self?.endKnobDrag()
        }
        addGestureRecognizer(knob)
        self.knobGesture = knob

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = true
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)
        self.doubleTapGesture = doubleTap

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.cancelsTouchesInView = false
        singleTap.delegate = self
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        self.singleTapGesture = singleTap
    }

    func presentSelectionInPlace() {
        if !reduceMotion {
            highlightLayer.opacity = 0
            leadingKnob.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
            trailingKnob.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
            leadingKnob.alpha = 0
            trailingKnob.alpha = 0

            let targetOpacity: Float = (dark || layout.isUser) ? 0.36 : 0.22
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = targetOpacity
            fade.duration = 0.14
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            highlightLayer.opacity = targetOpacity
            highlightLayer.add(fade, forKey: "appear")

            UIView.animate(
                withDuration: 0.24,
                delay: 0,
                usingSpringWithDamping: 0.68,
                initialSpringVelocity: 0.4,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.leadingKnob.transform = .identity
                self.trailingKnob.transform = .identity
                self.leadingKnob.alpha = 1
                self.trailingKnob.alpha = 1
            }
        }
        presentEditMenu()
    }

    func ensureEditMenuPresented() {
        guard !isDismissing, activeDraggedKnob == nil, window != nil else { return }
        presentEditMenu()
    }

    func presentEditMenu() {
        guard !isDismissing, window != nil, selectedRange.length > 0 else { return }
        let target = clampedVisibleMenuRect()
        let config = UIEditMenuConfiguration(
            identifier: nil,
            sourcePoint: CGPoint(x: target.midX, y: target.minY)
        )
        editMenuInteraction?.presentEditMenu(with: config)
    }

    func dismissSelection(animated: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        stopAutoScroll()
        editMenuInteraction?.dismissMenu()
        isUserInteractionEnabled = false
        if animated && !reduceMotion && window != nil {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                self.alpha = 0
                self.leadingKnob.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                self.trailingKnob.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            } completion: { _ in
                self.removeFromSuperview()
            }
        } else {
            removeFromSuperview()
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopAutoScroll()
        }
    }

    // MARK: - Knob Hit-Testing & 120Hz Dragging

    private func knobSide(at point: CGPoint) -> DraggedKnob? {
        let leadRect = leadingKnob.frame.insetBy(dx: -8, dy: -6)
        let trailRect = trailingKnob.frame.insetBy(dx: -8, dy: -6)
        let hitLead = leadRect.contains(point)
        let hitTrail = trailRect.contains(point)
        if hitLead && hitTrail {
            let dLead = hypot(point.x - leadingKnob.frame.midX, point.y - leadingKnob.frame.midY)
            let dTrail = hypot(point.x - trailingKnob.frame.midX, point.y - trailingKnob.frame.midY)
            return dLead <= dTrail ? .leading : .trailing
        }
        if hitLead { return .leading }
        if hitTrail { return .trailing }
        return nil
    }

    private func beginKnobDrag(at point: CGPoint) {
        guard let side = knobSide(at: point) else { return }
        activeDraggedKnob = side
        editMenuInteraction?.dismissMenu()

        if let pan = webView?.scrollView.panGestureRecognizer, pan.isEnabled {
            pan.isEnabled = false
            pan.isEnabled = true
        }

        switch side {
        case .leading:
            fixedAnchorIndex = NSMaxRange(selectedRange)
            dragTouchOffset = CGPoint(
                x: leadingAnchorTextPoint.x - point.x,
                y: leadingAnchorTextPoint.y - point.y
            )
        case .trailing:
            fixedAnchorIndex = selectedRange.location
            dragTouchOffset = CGPoint(
                x: trailingAnchorTextPoint.x - point.x,
                y: trailingAnchorTextPoint.y - point.y
            )
        }
        if let webView {
            lastTouchInWebView = convert(point, to: webView)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.55)
    }

    private func continueKnobDrag(at point: CGPoint) {
        guard activeDraggedKnob != nil else { return }
        if let webView {
            lastTouchInWebView = convert(point, to: webView)
            updateAutoScroll(touchInWebView: lastTouchInWebView, webView: webView)
        }
        applyDraggedPoint(point)
    }

    private func applyDraggedPoint(_ pointInSelf: CGPoint) {
        let targetPoint = CGPoint(
            x: pointInSelf.x + dragTouchOffset.x,
            y: pointInSelf.y + dragTouchOffset.y
        )
        let movingIndex = layout.characterIndex(at: targetPoint)
        let newRange = Self.normalizedNonEmptyRange(
            in: layout.nsText,
            anchor: fixedAnchorIndex,
            moving: movingIndex
        )
        activeDraggedKnob = movingIndex <= fixedAnchorIndex ? .leading : .trailing
        if newRange != selectedRange {
            selectedRange = newRange
            updateSelectionVisuals()
        }
    }

    private func endKnobDrag() {
        stopAutoScroll()
        guard activeDraggedKnob != nil else { return }
        activeDraggedKnob = nil
        presentEditMenu()
    }

    private func updateAutoScroll(touchInWebView: CGPoint, webView: WKWebView) {
        let topZone = max(webView.safeAreaInsets.top, headerInset) + 46
        let bottomZone = webView.bounds.height - max(webView.safeAreaInsets.bottom, 12) - 46
        let maxSpeed: CGFloat = 520

        if touchInWebView.y < topZone {
            let ratio = min(1, max(0, (topZone - touchInWebView.y) / 48))
            autoScrollSpeed = -maxSpeed * ratio
        } else if touchInWebView.y > bottomZone {
            let ratio = min(1, max(0, (touchInWebView.y - bottomZone) / 48))
            autoScrollSpeed = maxSpeed * ratio
        } else {
            autoScrollSpeed = 0
        }

        if abs(autoScrollSpeed) > 1 {
            if displayLink == nil {
                let target = SelectionDisplayLinkTarget()
                target.owner = self
                let link = CADisplayLink(target: target, selector: #selector(SelectionDisplayLinkTarget.step(_:)))
                if #available(iOS 15.0, *) {
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                }
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            stopAutoScroll()
        }
    }

    fileprivate func handleAutoScrollStep(_ link: CADisplayLink) {
        guard let webView, activeDraggedKnob != nil, abs(autoScrollSpeed) > 1 else {
            stopAutoScroll()
            return
        }
        let scrollView = webView.scrollView
        let dt = max(1.0 / 120.0, min(1.0 / 30.0, CGFloat(link.targetTimestamp - link.timestamp)))
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let nextY = min(maxY, max(minY, scrollView.contentOffset.y + autoScrollSpeed * dt))
        guard abs(nextY - scrollView.contentOffset.y) > 0.2 else { return }
        scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: nextY)
        let currentPointInSelf = convert(lastTouchInWebView, from: webView)
        applyDraggedPoint(currentPointInSelf)
    }

    private func stopAutoScroll() {
        autoScrollSpeed = 0
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Double-Tap Word Selection & Single-Tap Dismiss

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let pt = touch.location(in: self)
        if knobSide(at: pt) != nil {
            return false
        }
        if gestureRecognizer === doubleTapGesture {
            return layout.bubbleRect.insetBy(dx: -8, dy: -8).contains(pt)
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === singleTapGesture || gestureRecognizer === doubleTapGesture {
            if otherGestureRecognizer === webView?.scrollView.panGestureRecognizer {
                return true
            }
        }
        return false
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let pt = gesture.location(in: self)
        let index = layout.characterIndex(at: pt)
        let word = Self.wordRange(in: layout.nsText, at: index)
        guard word.length > 0 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
        selectedRange = word
        updateSelectionVisuals()
        presentEditMenu()
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onDismiss(true)
    }

    // MARK: - Selection Geometry Rendering

    private func updateSelectionVisuals() {
        var selectedGlyphRects: [CGRect] = []
        selectedGlyphRects.reserveCapacity(min(layout.glyphs.count, max(8, selectedRange.length)))

        for glyph in layout.glyphs {
            if glyph.endUTF16 <= selectedRange.location { continue }
            if glyph.startUTF16 >= NSMaxRange(selectedRange) { continue }
            if let r = glyph.slicedRect(for: selectedRange) {
                selectedGlyphRects.append(r)
            }
        }

        guard let firstGlyphRect = selectedGlyphRects.first,
              let lastGlyphRect = selectedGlyphRects.last else { return }

        var bands: [CGRect] = []
        for r in selectedGlyphRects {
            if let lastIdx = bands.indices.last,
               abs(r.midY - bands[lastIdx].midY) <= max(r.height, bands[lastIdx].height) * 0.45 {
                bands[lastIdx] = bands[lastIdx].union(r)
            } else {
                bands.append(r)
            }
        }
        bands = bands.map { $0.insetBy(dx: -1.5, dy: -1.0) }
        bands.sort { $0.minY < $1.minY }

        let scale = max(1.0, traitCollection.displayScale)
        if bands.count > 1 {
            for i in 0..<(bands.count - 1) {
                let gap = bands[i + 1].minY - bands[i].maxY
                if gap > -3.0 && gap <= 8.5 {
                    let mid = round(((bands[i].maxY + bands[i + 1].minY) * 0.5) * scale) / scale
                    bands[i].size.height = max(2, mid - bands[i].minY)
                    let nextMaxY = bands[i + 1].maxY
                    bands[i + 1].origin.y = mid
                    bands[i + 1].size.height = max(2, nextMaxY - mid)
                }
            }
        }

        let path = UIBezierPath()
        var unionRect = CGRect.null
        for band in bands {
            unionRect = unionRect.union(band)
            path.append(UIBezierPath(roundedRect: band, cornerRadius: 3.5))
        }
        selectionMenuRect = unionRect.isNull ? layout.bubbleRect : unionRect

        let firstBand = bands.first { $0.intersects(firstGlyphRect.insetBy(dx: -2, dy: -2)) } ?? firstGlyphRect
        let lastBand = bands.last { $0.intersects(lastGlyphRect.insetBy(dx: -2, dy: -2)) } ?? lastGlyphRect

        leadingAnchorTextPoint = CGPoint(x: firstGlyphRect.minX, y: firstGlyphRect.midY)
        trailingAnchorTextPoint = CGPoint(x: lastGlyphRect.maxX, y: lastGlyphRect.midY)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlightLayer.path = path.cgPath
        leadingKnob.updatePlacement(
            stemX: firstGlyphRect.minX,
            topY: firstBand.minY,
            bottomY: firstBand.maxY
        )
        trailingKnob.updatePlacement(
            stemX: lastGlyphRect.maxX,
            topY: lastBand.minY,
            bottomY: lastBand.maxY
        )
        CATransaction.commit()
    }

    // MARK: - UIEditMenuInteractionDelegate

    private func clampedVisibleMenuRect() -> CGRect {
        let base = selectionMenuRect.isNull || selectionMenuRect.isEmpty ? layout.bubbleRect : selectionMenuRect
        guard let webView else { return base }
        let safeTop = max(webView.safeAreaInsets.top, headerInset) + 46
        let safeBottom = max(safeTop + 44, webView.bounds.height - max(webView.safeAreaInsets.bottom, 12) - 46)
        let visibleInWeb = CGRect(
            x: 16,
            y: safeTop,
            width: max(40, webView.bounds.width - 32),
            height: safeBottom - safeTop
        )
        let visibleInSelf = convert(visibleInWeb, from: webView)
        let intersected = base.intersection(visibleInSelf)
        if !intersected.isNull && intersected.height >= 4 && intersected.width >= 4 {
            return intersected
        }
        let clampedY = min(max(base.minY, visibleInSelf.minY), visibleInSelf.maxY - 20)
        return CGRect(
            x: min(max(base.minX, visibleInSelf.minX), visibleInSelf.maxX - 20),
            y: clampedY,
            width: min(max(24, base.width), visibleInSelf.width),
            height: 20
        )
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        clampedVisibleMenuRect()
    }

    func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        let fullRange = NSRange(location: 0, length: layout.nsText.length)
        var items: [UIMenuElement] = [
            UIAction(title: String(localized: "拷贝", bundle: AppLanguage.resourceBundle)) { [weak self] _ in
                guard let self else { return }
                let str = self.selectedText()
                if !str.isEmpty {
                    ChatWebCoordinator.copyTextToPasteboard(str)
                }
                self.onDismiss(true)
            }
        ]
        if selectedRange != fullRange && fullRange.length > 0 {
            items.append(
                UIAction(title: String(localized: "全选", bundle: AppLanguage.resourceBundle)) { [weak self] _ in
                    guard let self else { return }
                    self.selectedRange = fullRange
                    self.updateSelectionVisuals()
                    DispatchQueue.main.async { [weak self] in
                        self?.presentEditMenu()
                    }
                }
            )
        }
        items.append(
            UIAction(title: String(localized: "共享…", bundle: AppLanguage.resourceBundle)) { [weak self] _ in
                guard let self else { return }
                let str = self.selectedText()
                let anchorRect = self.clampedVisibleMenuRect()
                let hostWebView = self.webView
                let anchorInWeb = hostWebView.map { self.convert(anchorRect, to: $0) } ?? .zero
                self.onDismiss(true)
                guard !str.isEmpty, let presenter = Self.topViewController(from: hostWebView) else { return }
                let activity = UIActivityViewController(activityItems: [str], applicationActivities: nil)
                if let pop = activity.popoverPresentationController, let hostWebView {
                    pop.sourceView = hostWebView
                    pop.sourceRect = anchorInWeb
                }
                presenter.present(activity, animated: true)
            }
        )
        return UIMenu(title: "", children: items)
    }

    private func selectedText() -> String {
        let len = layout.nsText.length
        let s = max(0, min(len, selectedRange.location))
        let e = max(s, min(len, NSMaxRange(selectedRange)))
        guard e > s else { return "" }
        return layout.nsText.substring(with: NSRange(location: s, length: e - s))
    }

    private static func topViewController(from view: UIView?) -> UIViewController? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                var top = vc
                while let presented = top.presentedViewController, !presented.isBeingDismissed {
                    top = presented
                }
                return top
            }
            responder = next
        }
        return nil
    }

    // MARK: - Text Tokenization & Initial Range

    private static func normalizedNonEmptyRange(in nsText: NSString, anchor: Int, moving: Int) -> NSRange {
        let total = nsText.length
        guard total > 0 else { return NSRange(location: 0, length: 0) }
        var low = max(0, min(total, min(anchor, moving)))
        var high = max(0, min(total, max(anchor, moving)))
        if low == high {
            if low < total {
                let seq = nsText.rangeOfComposedCharacterSequence(at: low)
                low = seq.location
                high = NSMaxRange(seq)
            } else {
                let seq = nsText.rangeOfComposedCharacterSequence(at: total - 1)
                low = seq.location
                high = NSMaxRange(seq)
            }
        }
        return nsText.rangeOfComposedCharacterSequences(for: NSRange(location: low, length: max(1, high - low)))
    }

    private static func computeInitialRange(layout: ExtractedBubbleSelectionLayout, pressPoint: CGPoint) -> NSRange {
        let nsText = layout.nsText
        let total = nsText.length
        guard total > 0 else { return NSRange(location: 0, length: 0) }
        if layout.lines.count <= 12 && total <= 280 {
            return NSRange(location: 0, length: total)
        }
        let approx = min(max(0, layout.characterIndex(at: pressPoint)), total - 1)
        var probe = approx
        while probe < total, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(nsText.character(at: probe)) ?? UnicodeScalar(32)) {
            probe += 1
        }
        if probe >= total {
            probe = approx
            while probe > 0, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(nsText.character(at: probe)) ?? UnicodeScalar(32)) {
                probe -= 1
            }
        }
        var para = nsText.paragraphRange(for: NSRange(location: probe, length: 0))
        while para.length > 0 {
            let lastChar = nsText.character(at: NSMaxRange(para) - 1)
            if lastChar == 10 || lastChar == 13 {
                para.length -= 1
            } else {
                break
            }
        }
        if para.length == 0 {
            return nsText.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(total, 140)))
        }
        if para.length <= 180 {
            return nsText.rangeOfComposedCharacterSequences(for: para)
        }
        let start = min(max(para.location, probe - 50), max(para.location, NSMaxRange(para) - 140))
        let cappedLen = min(140, NSMaxRange(para) - start)
        return nsText.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: max(1, cappedLen)))
    }

    private static func wordRange(in nsText: NSString, at index: Int) -> NSRange {
        let length = nsText.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let clamped = min(max(0, index), length - 1)
        if let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            nsText as CFString,
            CFRange(location: 0, length: length),
            UInt(kCFStringTokenizerUnitWord),
            CFLocaleCopyCurrent()
        ) {
            let tokenType = CFStringTokenizerGoToTokenAtIndex(tokenizer, clamped)
            if tokenType != [] {
                let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                if cfRange.location != kCFNotFound && cfRange.length > 0 {
                    let candidate = NSRange(location: cfRange.location, length: cfRange.length)
                    if !nsText.substring(with: candidate).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return nsText.rangeOfComposedCharacterSequences(for: candidate)
                    }
                }
            }
        }
        return nsText.rangeOfComposedCharacterSequence(at: clamped)
    }
}
#endif
