import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DesktopNotchPresentation {
    var expanded = false
    var pinned = false
}

/// A nonactivating panel attaches to the camera housing instead of consuming a menu-bar slot.
@MainActor
final class DesktopNotchCompanion: NSObject {
    let presentation = DesktopNotchPresentation()
    private var panel: CompanionPanel?
    private var host: NSHostingView<DesktopNotchView>?
    private var layout: DesktopNotchLayout?
    private var contentHeight: CGFloat = 180
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var inside = false
    private var localMonitor: Any?
    private var globalMonitor: Any?

    func install(model: DesktopModel, layout: DesktopNotchLayout, openChat: @escaping () -> Void, openSettings: @escaping () -> Void) {
        guard panel == nil else { return }
        self.layout = layout
        let panel = CompanionPanel(contentRect: layout.compactFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "MoMo"
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true; panel.becomesKeyOnlyIfNeeded = true
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.isMovable = false; panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        let view = DesktopNotchView(model: model, presentation: presentation, layout: layout,
            toggle: { [weak self] in self?.toggle() }, hover: { [weak self] in self?.hover($0) },
            heightChanged: { [weak self] in self?.resizeContent($0) },
            openChat: { [weak self] in self?.collapse(); openChat() },
            openSettings: { [weak self] in self?.collapse(); openSettings() },
            pin: { [weak self] in self?.pin() })
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel; self.host = host
        panel.onEscape = { [weak self] in self?.collapse() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        panel.orderFrontRegardless()
    }

    @objc private func spaceChanged() { collapse(); panel?.orderFrontRegardless() }

    private func hover(_ value: Bool) {
        inside = value; hoverTask?.cancel(); dismissTask?.cancel()
        if value {
            guard !presentation.expanded else { return }
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                guard let self, self.inside else { return }
                self.expand()
            }
        } else if !presentation.pinned {
            dismissTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, !self.inside, !self.presentation.pinned else { return }
                self.collapse()
            }
        }
    }

    private func toggle() {
        if presentation.expanded && presentation.pinned { collapse() }
        else { pin(); expand() }
    }
    func show() { pin(); expand() }
    private func pin() {
        presentation.pinned = true; dismissTask?.cancel(); panel?.makeKey()
    }
    private func expand() {
        guard !presentation.expanded, let layout else { return }
        hoverTask?.cancel(); presentation.expanded = true; panel?.hasShadow = true
        setFrame(layout.expandedFrame(contentHeight: contentHeight))
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.collapse() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel { self?.collapse() }
            return event
        }
    }
    private func resizeContent(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        if presentation.expanded, let layout { setFrame(layout.expandedFrame(contentHeight: height)) }
    }
    private func setFrame(_ frame: CGRect) {
        guard let panel else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { panel.setFrame(frame, display: true) }
        else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().setFrame(frame, display: true)
            }
        }
    }
    private func collapse() {
        hoverTask?.cancel(); dismissTask?.cancel()
        presentation.pinned = false; presentation.expanded = false
        if let layout { setFrame(layout.compactFrame) }
        panel?.hasShadow = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
    }
    func remove() {
        collapse(); panel?.close(); panel = nil; host = nil; layout = nil; inside = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

private final class CompanionPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct DesktopNotchView: View {
    let model: DesktopModel
    let presentation: DesktopNotchPresentation
    var layout: DesktopNotchLayout
    let toggle: () -> Void
    let hover: (Bool) -> Void
    let heightChanged: (CGFloat) -> Void
    let openChat: () -> Void
    let openSettings: () -> Void
    let pin: () -> Void

    var body: some View {
        DesktopNotchSurface(expanded: presentation.expanded) {
            if presentation.expanded {
                topControl.frame(width: layout.expandedWidth)
                DesktopCompanionCard(model: model, openChat: openChat, openSettings: openSettings,
                    quit: { model.shutdown(); NSApplication.shared.terminate(nil) }, pin: pin)
                    .frame(width: layout.expandedWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heightChanged($0) }
            } else {
                topControl
            }
        }
        .onHover(perform: hover).environment(\.colorScheme, .dark)
    }

    private var topControl: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Group {
                    if presentation.expanded { Image(systemName: presentation.pinned ? "pin.fill" : "pin").font(.system(size: 11)) }
                    else { Image("MoMoStill").renderingMode(.template).resizable().scaledToFit().frame(width: 25, height: 25) }
                }.frame(width: 44)
                Color.clear.frame(width: layout.notch.width)
                Group {
                    if let badge = model.companionState.badge {
                        Text(badge).font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    } else { Circle().fill(model.companionState.online ? .white.opacity(0.55) : .white.opacity(0.25)).frame(width: 4, height: 4) }
                }.frame(width: 44)
            }.frame(height: layout.topPadding).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(presentation.expanded ? (presentation.pinned ? "收起 MoMo" : "固定 MoMo") : "MoMo，\(model.companionState.subtitle)")
            .accessibilityIdentifier("companion.notch")
    }
}

struct DesktopCompanionAttachment: View {
    let model: DesktopModel
    let companion: DesktopCompanionController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        CompanionMainWindowReader { companion.mainWindow = $0 }.frame(width: 0, height: 0).onAppear {
            companion.install(model: model, openChat: {
                model.selection = "chat"
                if !companion.focusMainWindow() { openWindow(id: "main") }
                NSApplication.shared.activate(ignoringOtherApps: true)
            }, openSettings: { openSettings(); NSApplication.shared.activate(ignoringOtherApps: true) })
        }
    }
}

private struct CompanionMainWindowReader: NSViewRepresentable {
    let attached: (NSWindow) -> Void
    final class Host: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
    func makeNSView(context: Context) -> Host {
        let view = Host(); view.attached = attached; return view
    }
    func updateNSView(_ view: Host, context: Context) { view.attached = attached }
}
