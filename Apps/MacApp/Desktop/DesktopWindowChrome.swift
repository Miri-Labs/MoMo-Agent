import AppKit
import SwiftUI

/// Content extends behind the native controls without a separate titlebar surface.
/// Settings also hides its SwiftUI windowToolbar background; AppKit transparency alone
/// is overwritten by the Settings scene when its toolbar preferences are applied.
struct DesktopWindowChrome: NSViewRepresentable {
    final class Host: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyChrome()
        }
        override func layout() {
            super.layout()
            applyChrome()
        }
        func applyChrome() {
            guard let window else { return }
            if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
            if window.toolbar != nil { window.toolbar = nil }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            window.backgroundColor = NSColor(MoMoPalette.canvas)
            window.isMovableByWindowBackground = true
        }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ nsView: Host, context: Context) { nsView.applyChrome() }
}
