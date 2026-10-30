// A disposable native target. Only its button can create the receipt.
import AppKit

final class Probe: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let field = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Waiting for Hermes")
    let receipt = URL(fileURLWithPath: CommandLine.arguments[1])

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MoMoAgent Computer Use Probe"
        let title = NSTextField(labelWithString: "Hermes → MCP → Mac")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        field.placeholderString = "Enter the test marker"
        field.setAccessibilityLabel("Test marker")
        field.setAccessibilityIdentifier("probe-marker")
        field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        let button = NSButton(title: "Confirm test", target: self, action: #selector(confirm))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("probe-confirm")
        status.setAccessibilityIdentifier("probe-status")
        let stack = NSStackView(views: [title, field, button, status])
        stack.orientation = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func confirm() {
        guard field.stringValue.hasPrefix("MOMO_CUA_") else {
            status.stringValue = "Invalid test marker"
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "marker": field.stringValue, "action": "native_button_clicked",
                "timestamp": Date().timeIntervalSince1970,
            ], options: [.sortedKeys])
            try data.write(to: receipt, options: [.atomic])
            status.stringValue = "Confirmed: " + field.stringValue
        } catch {
            status.stringValue = "Receipt failed: " + error.localizedDescription
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = Probe()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
