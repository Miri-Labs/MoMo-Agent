// Compile alongside the production DesktopPermissionState.swift. Never changes TCC.
import AppKit

@main struct DesktopPermissionProbe {
    @MainActor static func main() async throws {
        var available: Set<DesktopPermissionKind> = []
        var requested: [DesktopPermissionKind] = []
        var opened: [URL] = []
        var canOpen = true
        var checks = 0
        let url = URL(fileURLWithPath: "/Applications/MoMo Agent 测试.app")
        let state = DesktopPermissionState(applicationURL: url,
            check: { checks += 1; return available.contains($0) },
            request: { requested.append($0) },
            open: { opened.append($0); return canOpen })
        state.refresh()
        precondition(opened.isEmpty && requested.isEmpty && !state.allGranted)
        state.openSettings(.accessibility)
        precondition(requested == [.accessibility])
        precondition(opened.last?.absoluteString.hasSuffix("Privacy_Accessibility") == true)
        precondition(!state.isGranted(.accessibility), "Opening settings is not authorization")
        available.insert(.accessibility)
        state.refresh()
        let count = opened.count
        state.openSettings(.accessibility)
        precondition(opened.count == count, "Already granted permission must not open settings")
        canOpen = false
        state.openSettings(.screenRecording)
        precondition(state.failure != nil && !state.allGranted)
        canOpen = true
        state.openSettings(.screenRecording)
        precondition(state.failure == nil && state.selected == .screenRecording)
        precondition(opened.last?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
        available.insert(.screenRecording)
        state.refresh()
        precondition(state.allGranted)
        available.remove(.accessibility)
        state.refresh()
        precondition(!state.allGranted && state.isGranted(.screenRecording))
        let item = state.applicationDragItem()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        precondition(board.writeObjects([item.item as! NSPasteboardWriting]))
        let dragURL = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL
        precondition(dragURL == url, "Drag must export the actual bundle file URL")
        state.didDropApplication(true)
        precondition(state.dropAccepted && !state.allGranted, "Drop must not fake a grant")
        state.didDropApplication(false)
        precondition(!state.dropAccepted)
        let opensBeforeRefresh = opened.count
        state.returnToOverview()
        state.refresh()
        precondition(state.selected == nil && !state.dropAccepted && opened.count == opensBeforeRefresh)
        print("PASS: explicit action, truthful grants/revocation, failure/retry, actual bundle file URL, accepted/cancelled drop, return without auto-opening Settings")
    }
}
