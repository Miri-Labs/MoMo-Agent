import AppKit
import ApplicationServices
import Observation

enum DesktopPermissionKind: String, CaseIterable {
    case accessibility, screenRecording

    var title: String { self == .accessibility ? String(localized: "辅助功能") : String(localized: "屏幕录制") }
    var purpose: String { self == .accessibility ? String(localized: "操作键盘与鼠标") : String(localized: "查看屏幕内容") }
    var icon: String { self == .accessibility ? "cursorarrow" : "rectangle.dashed.badge.record" }
    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?" +
            (self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"))!
    }
}

/// Reads never prompt. Dragging registers the actual running app with macOS.
@MainActor @Observable final class DesktopPermissionState {
    let applicationURL: URL
    let applicationIcon: NSImage
    private(set) var selected: DesktopPermissionKind?
    private(set) var failure: String?
    private(set) var dropAccepted = false
    private var granted: Set<DesktopPermissionKind> = []
    @ObservationIgnored private let check: (DesktopPermissionKind) -> Bool
    @ObservationIgnored private let request: (DesktopPermissionKind) -> Void
    @ObservationIgnored private let open: (URL) -> Bool

    init(applicationURL: URL = Bundle.main.bundleURL,
         check: @escaping (DesktopPermissionKind) -> Bool = { kind in
             kind == .accessibility ? AXIsProcessTrusted() : CGPreflightScreenCaptureAccess()
         },
         request: @escaping (DesktopPermissionKind) -> Void = { kind in
             switch kind {
             case .accessibility:
                 let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                 _ = AXIsProcessTrustedWithOptions(options)
             case .screenRecording:
                 _ = CGRequestScreenCaptureAccess()
             }
         },
         open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.applicationURL = applicationURL
        self.applicationIcon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        self.check = check
        self.request = request
        self.open = open
    }

    var allGranted: Bool { DesktopPermissionKind.allCases.allSatisfy(isGranted) }
    func isGranted(_ kind: DesktopPermissionKind) -> Bool { granted.contains(kind) }

    func refresh() {
        let updated = Set(DesktopPermissionKind.allCases.filter(check))
        if granted != updated { granted = updated }
    }

    func openSettings(_ kind: DesktopPermissionKind) {
        refresh()
        guard !isGranted(kind) else { return }
        selected = kind
        dropAccepted = false
        request(kind)
        failure = open(kind.settingsURL) ? nil : String(localized: "未能打开系统设置，请稍后重试。")
        // Neither opening the pane nor dropping the app proves authorization.
        refresh()
    }

    func didDropApplication(_ accepted: Bool) {
        dropAccepted = accepted
        refresh()
    }

    func returnToOverview() {
        selected = nil
        dropAccepted = false
        failure = nil
    }

    func applicationDragItem() -> NSDraggingItem {
        NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
    }

}
