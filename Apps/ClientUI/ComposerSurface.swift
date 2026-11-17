import SwiftUI
#if os(macOS)
import AppKit

/// Zero-overhead Return / Shift+Return key interceptor that attaches an invisible NSView probe
/// instead of wrapping SwiftUI's TextField inside a nested NSHostingController (eliminating double layout on every keystroke).
struct ComposerReturnKeyHandler<Content: View>: View {
    var send: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(ComposerReturnKeyProbe(send: send))
    }
}

private struct ComposerReturnKeyProbe: NSViewRepresentable {
    var send: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        context.coordinator.probe = probe
        context.coordinator.send = send
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            let handled = MainActor.assumeIsolated {
                guard let coordinator else { return false }
                return coordinator.handle(event) == nil
            }
            return handled ? nil : event
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.probe = nsView
        context.coordinator.send = send
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
        coordinator.monitor = nil
        coordinator.probe = nil
        coordinator.send = {}
    }

    @MainActor final class Coordinator {
        weak var probe: NSView?
        var send: () -> Void = {}
        var monitor: Any?

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
                  let probe, !probe.isHiddenOrHasHiddenAncestor,
                  let window = probe.window, window.isKeyWindow, event.window === window,
                  let editor = window.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField,
                  field.isEnabled, editor.isEditable,
                  field.currentEditor() === editor else { return event }
            let probeRect = probe.convert(probe.bounds, to: nil).insetBy(dx: -12, dy: -12)
            let fieldRect = field.convert(field.bounds, to: nil)
            guard probeRect.intersects(fieldRect) else { return event }
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if modifiers == .command {
                return editor.hasMarkedText() || event.isARepeat ? nil : event
            }
            guard !editor.hasMarkedText() else { return event }
            if modifiers == .shift {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
            guard modifiers.isEmpty else { return event }
            if !event.isARepeat { send() }
            return nil
        }
    }
}
#endif

extension View {
    @ViewBuilder func composerSurface() -> some View {
        momoElevatedCard(cornerRadius: 24, shadowStrength: 0.85)
    }
}
