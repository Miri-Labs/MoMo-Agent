import AppKit
import ApplicationServices
import SwiftUI

@MainActor final class DesktopPermissionsController: NSObject, NSWindowDelegate {
    let state = DesktopPermissionState()
    private var overview: NSPanel?
    private var accessory: PermissionGuidePanel?
    private var following: Task<Void, Never>?
    private var displayedPermission: DesktopPermissionKind?
    private var listFrame: CGRect?
    private var lastSettingsFrame: CGRect?
    private var lastListCheck = Date.distantPast

    func present() {
        if overview == nil {
            let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "MoMo Agent"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            let hosting = NSHostingView(rootView: DesktopPermissions(state: state,
                open: { [weak self] in self?.open($0) },
                relaunch: { Self.relaunchApplication() },
                close: { [weak self] in self?.overview?.close() },
                resize: { [weak self] size in
                    guard let panel = self?.overview,
                          abs(panel.contentLayoutRect.height - size.height) > 1 else { return }
                    panel.setContentSize(size)
                }))
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            panel.center()
            overview = panel
        }
        state.refresh()
        returnToOverview()
        startMonitoring()
    }

    func startMonitoring() {
        state.refresh()
        guard following == nil else { return }
        following = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
                guard !Task.isCancelled else { break }
                guard let self else { break }
                self.refreshPresentation()
            }
        }
    }

    func stopMonitoring() {
        following?.cancel(); following = nil
        accessory?.orderOut(nil)
        state.returnToOverview()
        displayedPermission = nil
    }

    func open(_ kind: DesktopPermissionKind) {
        state.openSettings(kind)
        guard state.selected == kind, state.failure == nil else { return }
        displayedPermission = kind
        lastListCheck = .distantPast
        if accessory == nil {
            let panel = PermissionGuidePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = String(localized: "MoMo Agent · 权限引导")
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let hosting = NSHostingView(rootView: DesktopPermissionAccessory(state: state,
                back: { [weak self] in self?.returnToOverview() }))
            panel.contentView = hosting
            panel.setContentSize(hosting.fittingSize)
            accessory = panel
        }
        overview?.orderOut(nil)
        startMonitoring()
        refreshPresentation()
    }

    private func returnToOverview() {
        state.returnToOverview()
        displayedPermission = nil
        accessory?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard let overview else { return }
        if let content = overview.contentView { overview.setContentSize(content.fittingSize) }
        overview.makeKeyAndOrderFront(nil)
    }

    private func refreshPresentation() {
        state.refresh()
        guard let kind = displayedPermission else { return }
        if state.isGranted(kind) { returnToOverview(); return }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first else {
            returnToOverview(); return
        }
        guard let accessory else { return }
        // Track only Settings geometry; this reads no pixels and needs no existing TCC grant.
        guard let target = Self.settingsFrame(pid: settings.processIdentifier) else {
            accessory.orderOut(nil); return
        }
        if let content = accessory.contentView { accessory.setContentSize(content.fittingSize) }
        let screens = NSScreen.screens
        let screen = screens.first { $0.frame.intersects(target) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? target
        let size = accessory.frame.size
        if lastSettingsFrame != target || Date().timeIntervalSince(lastListCheck) > 1 {
            lastSettingsFrame = target; lastListCheck = Date()
            listFrame = Self.permissionListFrame(pid: settings.processIdentifier, window: target)
        }
        // Screen Recording also has a second audio-only list. Point at the first permission list.
        // Before Accessibility is granted, keep the guide below the upper content area.
        let anchor = listFrame ?? CGRect(x: target.minX + target.width * 0.36,
                                         y: target.midY, width: target.width * 0.6, height: target.height * 0.3)
        let x = min(max(anchor.minX + 12, visible.minX + 8), visible.maxX - size.width - 8)
        let y = max(visible.minY + 8, anchor.minY - size.height + 22)
        accessory.setFrameOrigin(NSPoint(x: x, y: y))
        if settings.isActive || NSApp.isActive {
            accessory.orderFrontRegardless()
        } else { accessory.orderOut(nil) }
    }

    static func settingsFrame(pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
                  ($0[kCGWindowLayer as String] as? Int) == 0 &&
                  ($0[kCGWindowBounds as String] as? [String: Any]).flatMap({ CGRect(dictionaryRepresentation: $0 as CFDictionary) }).map({ $0.width > 400 && $0.height > 300 }) == true
              }), let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primary = NSScreen.screens.first else { return nil }
        return CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func permissionListFrame(pid: pid_t, window: CGRect) -> CGRect? {
        guard AXIsProcessTrusted(), let primary = NSScreen.screens.first else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(80))
        func value(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
            guard ContinuousClock.now < deadline else { return nil }
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute, &result) == .success ? result : nil
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = value(element, kAXPositionAttribute as CFString),
                  let size = value(element, kAXSizeAttribute as CFString),
                  CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero, extent = CGSize.zero
            guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
                  AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
            return CGRect(x: origin.x, y: primary.frame.maxY - origin.y - extent.height,
                          width: extent.width, height: extent.height)
        }
        var remaining = 180
        func firstList(_ element: AXUIElement, depth: Int) -> CGRect? {
            guard depth < 14, remaining > 0 else { return nil }
            remaining -= 1
            if let role = value(element, kAXRoleAttribute as CFString) as? String,
               role == (kAXListRole as String) || role == (kAXTableRole as String),
               let bounds = frame(element), bounds.width > 180, bounds.height > 40,
               bounds.minX > window.minX + window.width * 0.25 { return bounds }
            let children = value(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
            for child in children { if let found = firstList(child, depth: depth + 1) { return found } }
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        // Never stall the permission UI on an unresponsive Settings process.
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = value(app, kAXWindowsAttribute as CFString) as? [AXUIElement], let first = windows.first else { return nil }
        return firstList(first, depth: 0)
    }

    func windowWillClose(_ notification: Notification) {
        stopMonitoring()
    }

    static func relaunchApplication() {
        let bundlePath = Bundle.main.bundleURL.path
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", "sleep 0.6; open \"$1\"", "--", bundlePath]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try? launcher.run()
        NSApp.terminate(nil)
    }

    deinit { following?.cancel() }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
