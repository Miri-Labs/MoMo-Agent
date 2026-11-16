// Offline native fixture. Run: bash Tests/Support/check-chat-composer-return.sh
// Compiles the production handler and dispatches events through NSApplication's local monitor.
import AppKit
import SwiftUI

@main
@MainActor
struct ComposerReturnSmoke {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
        checks += 1
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let state = FixtureState()
        // A nonactivating panel can own native keyboard focus without activating a command-line app.
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260),
                             styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Fixture(state: state))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        pump()
        window.makeKey()
        check(window.isKeyWindow, "Fixture window must actually be key for native event delivery")
        let field = fields(in: hosting).first { $0.placeholderString == "Message" }!
        let other = fields(in: hosting).first { $0.placeholderString == "Other" }!
        func focus(_ field: NSTextField) -> NSTextView {
            check(window.makeFirstResponder(field), "Native field must accept focus")
            let editor = window.firstResponder as! NSTextView
            check(field.currentEditor() === editor, "Focused field must own the current editor")
            return editor
        }
        var editor = focus(field)
        pump()
        check(state.composerFocused, "Existing SwiftUI FocusState must follow native focus")
        func event(_ code: UInt16 = 36, _ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false,
                   in target: NSWindow? = nil, type: NSEvent.EventType = .keyDown) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: (target ?? window).windowNumber, context: nil,
                             characters: code == 76 ? "\u{3}" : "\r",
                             charactersIgnoringModifiers: code == 76 ? "\u{3}" : "\r",
                             isARepeat: repeatKey, keyCode: code)!
        }
        func press(_ code: UInt16 = 36, _ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) {
            app.sendEvent(event(code, modifiers, repeatKey: repeatKey))
            pump()
        }
        press()
        check(state.sent == ["hello"], "Return must send through the installed handler")
        check(state.text == "hello", "Return must not insert a newline")
        let oneLineHeight = field.frame.height
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        press(36, .shift)
        check(state.sent.count == 1 && state.text == "hello\n", "Shift+Return must only insert a newline")
        check(field.frame.height > oneLineHeight, "Existing multiline field must grow")
        press(76, .shift)
        check(state.sent.count == 1 && state.text == "hello\n\n", "Shift+keypad Enter must insert a newline")
        press(76, .numericPad)
        check(state.sent == ["hello", "hello\n\n"], "Keypad Enter must send the complete draft")
        press(36, .capsLock)
        check(state.sent.count == 3, "Caps Lock must not prevent sending")
        for code: UInt16 in [36, 76] {
            press(code, repeatKey: true)
        }
        check(state.sent.count == 3, "Holding Return or keypad Enter must not repeatedly send")
        press(36, .command)
        check(state.sent.count == 4, "Existing Command+Return shortcut must send once")
        press(36, .command, repeatKey: true)
        check(state.sent.count == 4, "Holding Command+Return must not repeatedly send")
        state.text = (1...5).map(String.init).joined(separator: "\n")
        pump()
        let fiveLineHeight = field.frame.height
        state.text = (1...10).map(String.init).joined(separator: "\n")
        pump()
        check(field.frame.height == fiveLineHeight, "Existing five-line display limit must remain intact")
        state.text = "short"
        pump()
        check(field.frame.height == oneLineHeight, "Field must shrink when the draft becomes short")
        print("PASS: Return, keypad, Shift newline, modifiers, repeat, Command+Return, multiline sizing")

        for sample in ["中文", "日本語"] {
            for (code, modifiers): (UInt16, NSEvent.ModifierFlags) in [(36, []), (76, []), (36, .shift), (36, .command)] {
                state.text = ""
                pump()
                editor = focus(field)
                editor.setMarkedText(sample, selectedRange: NSRange(location: (sample as NSString).length, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                check(editor.hasMarkedText(), "Fixture must create actual native marked text")
                let count = state.sent.count
                press(code, modifiers)
                check(state.sent.count == count, "Marked-text confirmation must not send: \(sample), \(modifiers)")
                // Complete the NSTextInputClient commit without switching the user's input source.
                editor.insertText(sample, replacementRange: editor.markedRange())
                pump()
                check(!editor.hasMarkedText() && state.text.contains(sample), "Native commit must update the SwiftUI binding")
                press(code, modifiers, repeatKey: true)
                check(state.sent.count == count, "Repeating the confirmation key after commit must not send")
                press()
                check(state.sent.count == count + 1,
                      "A separate Return after composition must send: sample=\(sample), modifiers=\(modifiers.rawValue), draft=\(state.text.debugDescription), editor=\(editor.string.debugDescription), focused=\(window.firstResponder === editor)")
            }
        }
        print("PASS: Chinese/Japanese native marked text, confirmation, post-commit repeats and explicit send")

        // Focus is changed synchronously, before SwiftUI has time to update its FocusState.
        let countBeforeFocus = state.sent.count
        _ = focus(other)
        app.sendEvent(event())
        app.sendEvent(event(36, .shift))
        check(state.sent.count == countBeforeFocus, "Another field in the same window must not send the composer")
        pump()
        check(!state.composerFocused, "Focus loss must propagate out of the existing field")
        check(window.makeFirstResponder(nil), "Must be able to resign text focus")
        app.sendEvent(event())
        pump()
        check(state.sent.count == countBeforeFocus, "Return without text focus must not send")

        editor = focus(field)
        pump()
        let foreignWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
                                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        foreignWindow.isReleasedWhenClosed = false
        let foreignField = NSTextField(string: "foreign")
        foreignWindow.contentView = foreignField
        foreignWindow.makeKeyAndOrderFront(nil)
        _ = foreignWindow.makeFirstResponder(foreignField)
        app.sendEvent(event(in: foreignWindow))
        check(state.sent.count == countBeforeFocus, "Another window must not send the composer")
        // Exercise rejection branches on the same production coordinator, using real native controls.
        let handler = ComposerReturnKeyHandler<EmptyView>.Coordinator()
        handler.view = field.superview!
        handler.send = { check(false, "Rejected event must not send") }
        check(handler.handle(event()) != nil, "An inactive composer window must pass the event through")
        foreignWindow.close()
        window.makeKeyAndOrderFront(nil)
        editor = focus(field)
        pump()
        for modifiers: NSEvent.ModifierFlags in [.option, .control, [.shift, .command], [.command, .option]] {
            check(handler.handle(event(36, modifiers)) != nil, "Unrelated modifier combinations must pass through")
        }
        check(handler.handle(event(229)) != nil, "229 is not an AppKit Return key")
        check(handler.handle(event(type: .keyUp)) != nil, "Key-up must pass through")
        handler.view!.isHidden = true
        check(handler.handle(event()) != nil, "A hidden input must pass through")
        handler.view!.isHidden = false
        _ = focus(other)
        check(handler.handle(event()) != nil, "A shared field editor must be checked against its owning control")
        handler.view = nil
        check(handler.handle(event()) != nil, "A detached handler must pass through")
        print("PASS: immediate focus loss, other field, no responder, other/inactive window and unrelated keys")

        editor = focus(field)
        state.text = " \n "
        pump()
        let countBeforeGates = state.sent.count
        press()
        press(36, .command)
        check(state.sent.count == countBeforeGates, "Whitespace-only drafts must not send")
        state.hasAttachment = true
        pump()
        press()
        check(state.sent.count == countBeforeGates + 1, "An attachment-only draft must send")
        state.disabled = true
        pump()
        press()
        press(36, .command)
        check(state.sent.count == countBeforeGates + 1, "Disabled sending must not send")
        state.disabled = false
        state.text = "draft after update"
        state.callbackVersion = 2
        pump()
        press()
        check(state.callbackVersions.last == 2 && state.sent.last == state.text, "Handler must use the updated send closure")
        print("PASS: whitespace, attachment-only, disabled gate and updated callback")

        state.parentDisabled = true
        pump()
        check(!field.isEnabled, "Hosted field must retain the parent's disabled environment")
        let countBeforeDisabledParent = state.sent.count
        press()
        check(state.sent.count == countBeforeDisabledParent, "A disabled parent must not send through the monitor")
        state.parentDisabled = false
        pump()

        let countBeforeRemoval = state.sent.count
        state.showComposer = false
        pump()
        _ = focus(other)
        app.sendEvent(event())
        check(state.sent.count == countBeforeRemoval, "Dismantled handler must not intercept events")
        state.showComposer = true
        pump()
        let newField = fields(in: hosting).first { $0.placeholderString == "Message" }!
        _ = focus(newField)
        pump()
        press()
        check(state.sent.count == countBeforeRemoval + 1, "Remount must install exactly one handler")
        print("PASS: removal and remount; \(checks) native behavior assertions")
    }

    static func pump() {
        let deadline = Date(timeIntervalSinceNow: 0.1)
        while Date() < deadline,
              let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    static func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    @Observable final class FixtureState {
        var text = "hello"
        var other = "other text"
        var sent: [String] = []
        var callbackVersions: [Int] = []
        var callbackVersion = 1
        var hasAttachment = false
        var disabled = false
        var parentDisabled = false
        var composerFocused = false
        var showComposer = true
        var canSend: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachment) && !disabled }
        func send(version: Int) {
            if canSend {
                sent.append(text)
                callbackVersions.append(version)
            }
        }
    }

    struct Fixture: View {
        @Bindable var state: FixtureState
        @FocusState private var focused: Bool
        var body: some View {
            let version = state.callbackVersion
            VStack {
                if state.showComposer {
                    ComposerReturnKeyHandler(send: { state.send(version: version) }) {
                        TextField("Message", text: $state.text, axis: .vertical)
                            .phoneText(.body)
                            .lineLimit(1...5).textFieldStyle(.plain)
                            .focused($focused)
                            .onChange(of: focused) { state.composerFocused = focused }
                    }
                }
                TextField("Other", text: $state.other, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain)
                Button("Send") { state.send(version: version) }
                    .disabled(!state.canSend)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .disabled(state.parentDisabled)
        }
    }
}
