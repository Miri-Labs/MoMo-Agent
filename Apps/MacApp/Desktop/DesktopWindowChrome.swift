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

