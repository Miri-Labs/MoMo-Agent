import AppKit
import SwiftUI

/// Content extends behind the native controls without a separate titlebar surface.
/// Deliberately avoids `isMovableByWindowBackground = true` on the whole window so AppKit never
/// intercepts hit-testing/drag gestures inside WKWebView, NSTableView, NSTextView, or buttons.
struct DesktopWindowChrome: NSViewRepresentable {
    final class Host: NSView {
        private weak var configuredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyChrome(force: true)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyChrome(force: true)
        }

        func applyChrome(force: Bool = false) {
            guard let window else { return }
            guard force || configuredWindow !== window else { return }
            configuredWindow = window
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if window.toolbar != nil { window.toolbar = nil }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if window.isMovableByWindowBackground { window.isMovableByWindowBackground = false }
            window.backgroundColor = NSColor(MoMoPalette.sidebar)
        }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ nsView: Host, context: Context) { nsView.applyChrome() }
}

/// Explicit window-drag region (equivalent to Grok Bot's `--sand-app-region: drag`) placed only in header chrome.
struct DesktopWindowDragRegion: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Expands the macOS window rightward when the right detail inspector opens (if screen space allows),
/// Keeps the left workspace pane's width locked when toggling the right detail inspector by
/// synchronously expanding the `NSWindow` frame by `inspectorWidth` (borrowing screen room from
/// the left edge if the window is near the right edge) and restoring it on close.
struct DesktopWindowInspectorExpander: NSViewRepresentable {
    let isOpen: Bool
    let inspectorWidth: CGFloat

    final class Host: NSView {
        private var initialized = false
        private var lastOpen = false
        private var expandedDelta: CGFloat = 0
        private var shiftedLeft: CGFloat = 0

        func needsSync(isOpen: Bool) -> Bool {
            !initialized || isOpen != lastOpen
        }

        func sync(isOpen: Bool, inspectorWidth: CGFloat) {
            guard let window else { return }
            if !initialized {
                initialized = true
                lastOpen = isOpen
                return
            }
            guard isOpen != lastOpen else { return }
            lastOpen = isOpen

            guard !window.styleMask.contains(.fullScreen) else {
                if !isOpen {
                    expandedDelta = 0
                    shiftedLeft = 0
                }
                return
            }

            if isOpen {
                let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                guard let visible else { return }
                let rightRoom = max(0, visible.maxX - window.frame.maxX)
                let leftRoom = max(0, window.frame.minX - visible.minX)
                let expandRight = min(inspectorWidth, rightRoom)
                let borrowLeft = min(max(0, inspectorWidth - expandRight), leftRoom)
                let totalDelta = expandRight + borrowLeft
                if totalDelta >= 12 {
                    var nextFrame = window.frame
                    nextFrame.origin.x -= borrowLeft
                    nextFrame.size.width += totalDelta
                    expandedDelta = totalDelta
                    shiftedLeft = borrowLeft
                    window.setFrame(nextFrame, display: false, animate: false)
                } else {
                    expandedDelta = 0
                    shiftedLeft = 0
                }
            } else {
                guard expandedDelta > 0 else { return }
                var nextFrame = window.frame
                let minWidth = max(window.minSize.width, 820)
                let shrink = min(expandedDelta, max(0, nextFrame.size.width - minWidth))
                nextFrame.size.width -= shrink
                nextFrame.origin.x += min(shiftedLeft, shrink)
                expandedDelta = 0
                shiftedLeft = 0
                window.setFrame(nextFrame, display: false, animate: false)
            }
        }
    }

    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ nsView: Host, context: Context) {
        guard nsView.needsSync(isOpen: isOpen) else { return }
        if nsView.window != nil {
            nsView.sync(isOpen: isOpen, inspectorWidth: inspectorWidth)
        } else {
            DispatchQueue.main.async {
                nsView.sync(isOpen: isOpen, inspectorWidth: inspectorWidth)
            }
        }
    }
}
