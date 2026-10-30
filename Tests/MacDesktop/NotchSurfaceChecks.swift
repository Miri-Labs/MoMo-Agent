import AppKit
import SwiftUI

private struct HeaderProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@main
enum NotchSurfaceChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        let probe = NSView()
        let host = NSHostingView(rootView: surface(expanded: true, probe: probe))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 360, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.displayIfNeeded()

        // Switch to compact content while its AppKit window is still expanded,
        // then sample intermediate native resize frames in both directions.
        host.rootView = surface(expanded: false, probe: probe)
        for height: CGFloat in [400, 320, 220, 100, 38, 100, 220, 320, 400] {
            window.setFrame(CGRect(x: 100, y: 700 - height, width: 360, height: height), display: true)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let frame = probe.convert(probe.bounds, to: host)
            precondition(abs(frame.minY) < 1, "Compact content moved away from the top: \(frame) at height \(height)")
            precondition(abs(frame.height - 38) < 1)
            precondition(window.frame.maxY == 700)
        }
        window.close()
        print("Notch surface checks passed: compact header remains at top in all intermediate collapse and expand frames")
    }

    @MainActor private static func surface(expanded: Bool, probe: NSView) -> some View {
        DesktopNotchSurface(expanded: expanded) {
            HeaderProbe(view: probe).frame(width: 288, height: 38)
            if expanded { Color.black.frame(width: 360, height: 362) }
        }
    }
}
