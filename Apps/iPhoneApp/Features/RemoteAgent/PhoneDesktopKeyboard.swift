import SwiftUI
import UIKit
import MoMoAgentClient

/// UITextView owns IME composition; only committed edits become remote input.
struct PhoneDesktopKeyboard: UIViewRepresentable {
    let active: Bool
    let sendText: (String) -> Void
    let sendKey: (String, [String]) -> Void
    let didClose: () -> Void
    func makeUIView(context: Context) -> RemoteTextView {
        let view = RemoteTextView()
        view.sendText = sendText; view.sendKey = sendKey; view.didClose = didClose
        view.installAccessory()
        view.autocorrectionType = .no; view.spellCheckingType = .no
        view.smartQuotesType = .no; view.smartDashesType = .no; view.smartInsertDeleteType = .no
        view.autocapitalizationType = .none
        view.text = RemoteTextView.sentinel; view.delegate = view
        view.selectedRange = NSRange(location: 1, length: 0)
        view.accessibilityIdentifier = "desktop.keyboardInput"; view.accessibilityLabel = "远程键盘"
        view.backgroundColor = .clear; view.textColor = .clear; view.tintColor = .clear
        view.isScrollEnabled = false
        return view
    }
    func updateUIView(_ view: RemoteTextView, context: Context) {
        view.sendText = sendText; view.sendKey = sendKey; view.didClose = didClose
        view.wantsKeyboard = active
        if active && !view.isFirstResponder { view.becomeFirstResponder() }
        else if !active && view.isFirstResponder { view.resignFirstResponder() }
    }
    static func dismantleUIView(_ view: RemoteTextView, coordinator: ()) { view.resignFirstResponder() }

    final class RemoteTextView: UITextView, UITextViewDelegate {
        static let sentinel = "\u{200B}"
        var sendText: (String) -> Void = { _ in }
        var sendKey: (String, [String]) -> Void = { _,_ in }
        var didClose: () -> Void = {}
        private var selectedModifiers: Set<String> = []
        private var modifierButtons: [String: UIButton] = [:]
        var wantsKeyboard = false
        func installAccessory() {
            let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 52), inputViewStyle: .keyboard)
            accessory.autoresizingMask = .flexibleWidth
            let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false; scroll.translatesAutoresizingMaskIntoConstraints = false
            let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
            accessory.addSubview(scroll); scroll.addSubview(stack)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: accessory.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: accessory.topAnchor), scroll.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
                stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
                stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
                stack.heightAnchor.constraint(equalToConstant: 44)
            ])
            for (name, title, modifier) in [("escape", "Esc", false), ("tab", "Tab", false), ("command", "⌘", true),
                ("option", "⌥", true), ("control", "⌃", true), ("shift", "⇧", true),
                ("left", "←", false), ("down", "↓", false), ("up", "↑", false), ("right", "→", false)] {
                var configuration = UIButton.Configuration.gray()
                configuration.title = title; configuration.cornerStyle = .capsule
                configuration.baseForegroundColor = .label
                configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    attributes.font = .systemFont(ofSize: 14, weight: .medium)
                    return attributes
                }
                let button = UIButton(configuration: configuration)
                button.titleLabel?.numberOfLines = 1
                button.widthAnchor.constraint(equalToConstant: name == "escape" || name == "tab" ? 48 : 44).isActive = true
                button.accessibilityIdentifier = modifier ? "desktop.modifier." + name : "desktop.key." + name
                button.accessibilityLabel = modifier ? name : title
                if modifier { modifierButtons[name] = button; button.accessibilityValue = "未选中" }
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let self else { return }
                    if modifier {
                        if selectedModifiers.contains(name) { selectedModifiers.remove(name) } else { selectedModifiers.insert(name) }
                        button?.isSelected = selectedModifiers.contains(name)
                        button?.accessibilityValue = selectedModifiers.contains(name) ? "已选中" : "未选中"
                    } else { emitKey(name, []) }
                }, for: .touchUpInside)
                stack.addArrangedSubview(button)
            }
            inputAssistantItem.leadingBarButtonGroups = []; inputAssistantItem.trailingBarButtonGroups = []
            inputAccessoryView = accessory
        }
        private func clearModifiers() {
            selectedModifiers = []
            for button in modifierButtons.values { button.isSelected = false; button.accessibilityValue = "未选中" }
        }
        private func emitKey(_ name: String, _ modifiers: [String]) {
            sendKey(name, Array(selectedModifiers.union(modifiers)).sorted()); clearModifiers()
        }
        private func emitText(_ value: String) {
            if !selectedModifiers.isEmpty, value.count == 1, value.unicodeScalars.first?.isASCII == true {
                emitKey(value == " " ? "space" : value.lowercased(), [])
            } else { sendText(value); clearModifiers() }
        }
        func textViewDidEndEditing(_ textView: UITextView) { clearModifiers(); didClose() }

        private lazy var remoteCommands: [UIKeyCommand] = {
            let combinations: [UIKeyModifierFlags] = [.command, [.command, .shift], [.command, .alternate], [.command, .shift, .alternate],
                .control, [.control, .shift], [.control, .alternate]]
            return combinations.flatMap { flags in
                Array("abcdefghijklmnopqrstuvwxyz0123456789").map { character in
                    let command = UIKeyCommand(input: String(character), modifierFlags: flags, action: #selector(remoteShortcut(_:)))
                    command.wantsPriorityOverSystemBehavior = true
                    return command
                }
            }
        }()
        override var keyCommands: [UIKeyCommand]? { remoteCommands + (super.keyCommands ?? []) }
        @objc private func remoteShortcut(_ command: UIKeyCommand) {
            guard let input = command.input else { return }
            let flags = command.modifierFlags
            let modifiers: [String] = [(UIKeyModifierFlags.command, "command"), (.control, "control"), (.alternate, "option"), (.shift, "shift")]
                .compactMap { flags.contains($0.0) ? $0.1 : nil }
            emitKey(input, modifiers)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil && wantsKeyboard { becomeFirstResponder() }
        }
        override func deleteBackward() {
            if markedTextRange == nil, text == Self.sentinel { emitKey("backspace", []); return }
            super.deleteBackward()
        }
        override func insertText(_ text: String) {
            if text == "\n", markedTextRange == nil { emitKey("return", []); return }
            if text == "\t", markedTextRange == nil { emitKey("tab", []); return }
            super.insertText(text)
        }
        func textViewDidChange(_ textView: UITextView) {
            guard markedTextRange == nil else { return }
            let committed = text.hasPrefix(Self.sentinel) ? String(text.dropFirst()) : text ?? ""
            guard !committed.isEmpty else { text = Self.sentinel; selectedRange = NSRange(location: 1, length: 0); return }
            emitText(committed); text = Self.sentinel
            selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var remaining = presses
            for press in presses {
                guard let key = press.key else { continue }
                let special: [UIKeyboardHIDUsage: String] = [.keyboardEscape: "escape", .keyboardTab: "tab", .keyboardReturnOrEnter: "return",
                    .keyboardDeleteOrBackspace: "backspace", .keyboardDeleteForward: "delete", .keyboardLeftArrow: "left",
                    .keyboardRightArrow: "right", .keyboardUpArrow: "up", .keyboardDownArrow: "down", .keyboardHome: "home",
                    .keyboardEnd: "end", .keyboardPageUp: "pageup", .keyboardPageDown: "pagedown"]
                let flags = key.modifierFlags
                let modifiers: [String] = [(UIKeyModifierFlags.command, "command"), (.control, "control"), (.alternate, "option"), (.shift, "shift")]
                    .compactMap { flags.contains($0.0) ? $0.1 : nil }
                let name = special[key.keyCode] ?? ((flags.contains(.command) || flags.contains(.control)) ? key.charactersIgnoringModifiers.lowercased() : nil)
                if let name, !name.isEmpty { emitKey(name == " " ? "space" : name, modifiers); remaining.remove(press) }
            }
            if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
        }
    }
}
