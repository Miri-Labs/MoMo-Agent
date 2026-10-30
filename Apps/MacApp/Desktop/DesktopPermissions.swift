import AppKit
import SwiftUI

struct DesktopPermissions: View {
    let state: DesktopPermissionState
    let open: (DesktopPermissionKind) -> Void
    let relaunch: () -> Void
    let close: () -> Void
    let resize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("屏幕与控制权限").font(.system(size: 22, weight: .medium))
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 16) {
                permission(.accessibility)
                Divider()
                permission(.screenRecording)
            }
            if !state.allGranted {
                Text("若系统设置中已有旧的同名 MoMo Agent，请先选中点底部「-」移除再重新开启；开启屏幕录制后需点「重启刷新」生效。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = state.failure {
                Text(failure).font(.callout).foregroundStyle(MoMoPalette.failure)
            }
            HStack(spacing: 10) {
                Spacer()
                if !state.allGranted {
                    Button("重启刷新", action: relaunch)
                        .buttonStyle(DesktopSetupButton(filled: false, minimumHeight: 36, fontSize: 13)).frame(width: 92)
                        .accessibilityIdentifier("permissions.relaunch")
                }
                Button(state.allGranted ? "完成" : "稍后", action: close)
                    .buttonStyle(DesktopSetupButton(filled: false, minimumHeight: 36, fontSize: 13)).frame(width: 72)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 440).fixedSize(horizontal: false, vertical: true)
        .background(MoMoPalette.canvas).foregroundStyle(MoMoPalette.ink).tint(MoMoPalette.ink)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { resize($0) }
    }

    private func permission(_ kind: DesktopPermissionKind) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.icon).font(.title3).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.title).font(.system(size: 14, weight: .medium))
                Text(kind.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if state.isGranted(kind) {
                Label("已开启", systemImage: "checkmark.circle.fill").font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("permissions.\(kind.rawValue).granted")
            } else {
                Button("开启") { open(kind) }
                    .buttonStyle(DesktopSetupButton(filled: false, minimumHeight: 36, fontSize: 13)).frame(width: 72)
                    .accessibilityLabel("开启\(kind.title)")
                    .accessibilityIdentifier("permissions.\(kind.rawValue).open")
            }
        }.desktopSettingsRow()
    }
}

/// The guide belongs to the selected permission, not to the overview window.
struct DesktopPermissionAccessory: View {
    let state: DesktopPermissionState
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).accessibilityLabel("返回权限列表")
                Spacer()
                Text(state.selected?.title ?? "").font(.caption).foregroundStyle(.secondary)
            }
            DesktopDraggableApplication(state: state).frame(height: 52)
                .accessibilityIdentifier("permissions.dragApplication")
            Text(state.dropAccepted ? "在上方列表中开启 MoMo Agent" : "将 MoMo Agent 拖入上方列表")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 300)
        .background(MoMoPalette.canvas, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)))
        .foregroundStyle(MoMoPalette.ink).tint(MoMoPalette.ink)
        .padding(.top, 34)
        .overlay(alignment: .topLeading) {
            DragDirection().stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 42, height: 40).padding(.leading, 35).allowsHitTesting(false).accessibilityHidden(true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DragDirection: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addQuadCurve(to: CGPoint(x: rect.minX + 8, y: rect.minY + 2),
                           control: CGPoint(x: rect.minX + 8, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX, y: rect.minY + 12))
            p.addLine(to: CGPoint(x: rect.minX + 8, y: rect.minY + 2))
            p.addLine(to: CGPoint(x: rect.minX + 18, y: rect.minY + 9))
        }
    }
}

struct DesktopDraggableApplication: NSViewRepresentable {
    let state: DesktopPermissionState

    func makeNSView(context: Context) -> ApplicationRow { ApplicationRow() }
    func updateNSView(_ view: ApplicationRow, context: Context) {
        view.icon.image = state.applicationIcon
        view.makeDragItem = state.applicationDragItem
        view.onDrop = state.didDropApplication
    }

    final class ApplicationRow: NSView, NSDraggingSource {
        let content = NSView()
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "MoMo Agent")
        var makeDragItem: (() -> NSDraggingItem)?
        var onDrop: ((Bool) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 10
            layer?.borderWidth = 1
            content.autoresizingMask = [.width, .height]
            addSubview(content)
            icon.imageScaling = .scaleProportionallyUpOrDown
            content.addSubview(icon)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            content.addSubview(label)
            setAccessibilityElement(true)
            setAccessibilityRole(.image)
            setAccessibilityLabel(String(localized: "MoMo Agent 应用"))
            setAccessibilityHelp(String(localized: "将这个 App 条目拖入系统设置的权限列表"))
            refreshAppearance()
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            content.frame = bounds
            icon.frame = NSRect(x: 12, y: (bounds.height - 32) / 2, width: 32, height: 32)
            label.frame = NSRect(x: 54, y: (bounds.height - 18) / 2, width: max(0, bounds.width - 64), height: 18)
        }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshAppearance() }
        private func refreshAppearance() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
        // System Settings stays active: the first press must begin the drag.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
        override func mouseDown(with event: NSEvent) {
            guard let item = makeDragItem?(), let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return }
            cacheDisplay(in: bounds, to: bitmap)
            let snapshot = NSImage(size: bounds.size)
            snapshot.addRepresentation(bitmap)
            item.setDraggingFrame(bounds, contents: snapshot)
            beginDraggingSession(with: [item], event: event, source: self)
                .animatesToStartingPositionsOnCancelOrFail = true
        }
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { content.isHidden = true }
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            content.isHidden = false
            onDrop?(operation.contains(.copy))
        }
    }
}
