import AppKit

/// Only physical camera housings get a notch surface. All other displays use AppKit's menu bar.
@MainActor
final class DesktopCompanionController: NSObject {
    weak var mainWindow: NSWindow?
    private let notch = DesktopNotchCompanion()
    private let menu = DesktopCompanionMenuBar()
    private var model: DesktopModel?
    private var openChat: (() -> Void)?
    private var openSettings: (() -> Void)?
    private var currentLayout: DesktopNotchLayout?
    private var installed = false
    private var screenTask: Task<Void, Never>?

    func install(model: DesktopModel, openChat: @escaping () -> Void, openSettings: @escaping () -> Void) {
        guard self.model == nil else { return }
        self.model = model; self.openChat = openChat; self.openSettings = openSettings
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        updateSurface()
    }

    @objc private func screenChanged() {
        // Wake and clamshell changes can reconnect displays in several steps.
        screenTask?.cancel()
        screenTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.updateSurface()
        }
    }

    private func updateSurface() {
        guard let model, let openChat, let openSettings else { return }
        let layout = NSScreen.screens.compactMap {
            DesktopNotchLayout(screen: $0.frame, safeTop: $0.safeAreaInsets.top,
                               left: $0.auxiliaryTopLeftArea, right: $0.auxiliaryTopRightArea)
        }.first
        guard !installed || layout != currentLayout else { return }
        notch.remove(); menu.remove()
        currentLayout = layout; installed = true
        if let layout {
            notch.install(model: model, layout: layout, openChat: openChat, openSettings: openSettings)
        } else {
            menu.install(model: model, openChat: openChat, openSettings: openSettings)
        }
    }

    func show() {
        if currentLayout != nil { notch.show() }
        else { menu.showPinned(fallback: mainWindow?.contentView) }
    }

    func focusMainWindow() -> Bool {
        guard let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized else { return false }
        if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
        mainWindow.makeKeyAndOrderFront(nil)
        return true
    }

    func remove() {
        screenTask?.cancel(); screenTask = nil
        NotificationCenter.default.removeObserver(self)
        notch.remove(); menu.remove()
        model = nil; openChat = nil; openSettings = nil; installed = false; currentLayout = nil
    }
}
