import AppKit

@MainActor final class DesktopFixture: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let field = NSTextField(string: "")
    private let check = NSButton(checkboxWithTitle: "启用测试选项", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "尚未保存")
    private var saves = 0
    private let output: URL

    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 520, height: 260),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MoMo Desktop E2E"
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "MoMo 电脑工具 · 本地验收")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        field.placeholderString = "输入测试内容"
        field.setAccessibilityLabel("测试内容")
        field.identifier = NSUserInterfaceItemIdentifier("momo.e2e.content")
        field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let button = NSButton(title: "保存测试内容", target: self, action: #selector(save))
        button.bezelStyle = .rounded
        status.setAccessibilityLabel("保存结果")
        status.maximumNumberOfLines = 2
        let stack = NSStackView(views: [title, field, check, button, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)
        ])
        window.makeKeyAndOrderFront(nil)
        persist()
    }

    @objc private func save() {
        saves += 1
        status.stringValue = "已保存 \(saves) 次：\(field.stringValue)"
        persist()
    }

    private func persist() {
        let record: [String: Any] = ["saves": saves, "text": field.stringValue, "checked": check.state == .on]
        do { try JSONSerialization.data(withJSONObject: record, options: .sortedKeys).write(to: output.appendingPathComponent("fixture-state.json"), options: .atomic) }
        catch { fputs("Fixture write failed\n", stderr); NSApplication.shared.terminate(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct FixtureMain {
    static func main() {
        let app = NSApplication.shared
        let fixture = DesktopFixture(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.setActivationPolicy(.regular); app.delegate = fixture
        app.run()
    }
}
