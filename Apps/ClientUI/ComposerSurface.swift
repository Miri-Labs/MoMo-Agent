import SwiftUI
#if os(macOS)
import AppKit

// Keep the existing SwiftUI field in its own native scope; a cached FocusState can lag focus changes.
struct ComposerReturnKeyHandler<Content: View>: NSViewControllerRepresentable {
    var send: () -> Void
    @ViewBuilder var content: () -> Content

    func makeNSViewController(context: Context) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: content())
        host.sizingOptions = [.intrinsicContentSize]
        context.coordinator.view = host.view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            let handled = MainActor.assumeIsolated {
                guard let coordinator else { return false }
                return coordinator.handle(event) == nil
            }
            return handled ? nil : event
        }
        return host
    }

    func updateNSViewController(_ host: NSHostingController<Content>, context: Context) {
        host.rootView = content()
        context.coordinator.send = send
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController host: NSHostingController<Content>, context: Context) -> CGSize? {
        host.sizeThatFits(in: CGSize(width: proposal.width ?? CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSViewController(_ host: NSHostingController<Content>, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        coordinator.view = nil
        coordinator.send = {}
    }

    @MainActor final class Coordinator {
        weak var view: NSView?
        var send: () -> Void = {}
        var monitor: Any?

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
                  let view, !view.isHiddenOrHasHiddenAncestor,
                  let window = view.window, window.isKeyWindow, event.window === window,
                  let editor = window.firstResponder as? NSTextView,
                  let field = editor.delegate as? NSTextField,
                  field.isEnabled, editor.isEditable,
                  field.isDescendant(of: view), field.currentEditor() === editor else { return event }
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if modifiers == .command {
                // Preserve the send button shortcut, but not repeats or a still-composing draft.
                return editor.hasMarkedText() || event.isARepeat ? nil : event
            }
            // Check before the input method handles Return and clears its marked range.
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
