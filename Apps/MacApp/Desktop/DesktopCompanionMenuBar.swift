import AppKit
import Observation
import SwiftUI

@MainActor
final class DesktopCompanionMenuBar: NSObject, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var tracking: NSTrackingArea?
    private var makeContent: (() -> NSViewController)?
    private var hoverTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var pinned = false
    private var inside = false
    private var generation = 0

    func install(model: DesktopModel, openChat: @escaping () -> Void, openSettings: @escaping () -> Void) {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        if let button = item.button {
            let image = NSImage(named: "MoMoMenuMark")?.copy() as? NSImage
            image?.size = NSSize(width: 18, height: 18); image?.isTemplate = true
            button.image = image; button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            button.target = self; button.action = #selector(toggle)
            button.setAccessibilityIdentifier("companion.menuBar")
            let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
            button.addTrackingArea(tracking); self.tracking = tracking
        }
        popover.delegate = self; popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        makeContent = { [weak self] in
            NSHostingController(rootView: DesktopCompanionCard(model: model,
                openChat: { self?.close(); openChat() }, openSettings: { self?.close(); openSettings() },
                quit: { model.shutdown(); NSApplication.shared.terminate(nil) },
                pin: { self?.pinned = true; self?.dismissTask?.cancel() })
                .frame(width: 360)
                .onHover { self?.hover($0) }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    if size.height > 0 { self?.popover.contentSize = size }
                })
        }
        observe(model, generation: generation)
    }

    private func observe(_ model: DesktopModel, generation: Int) {
        guard item != nil, generation == self.generation else { return }
        withObservationTracking {
            let state = model.companionState
            item?.button?.title = state.badge.map { " \($0)" } ?? ""
            item?.button?.toolTip = "MoMo Agent · \(state.subtitle)"
            item?.button?.setAccessibilityLabel("MoMo Agent，\(state.subtitle)")
        } onChange: { [weak self, weak model] in
            Task { @MainActor in
                guard let self, let model else { return }
                self.observe(model, generation: generation)
            }
        }
    }

    @objc private func toggle() {
        if popover.isShown && pinned { close() }
        else { pinned = true; dismissTask?.cancel(); show() }
    }
    func showPinned(fallback: NSView?) { pinned = true; dismissTask?.cancel(); show(fallback: fallback) }
    @objc func mouseEntered(with event: NSEvent) { hover(true) }
    @objc func mouseExited(with event: NSEvent) { hover(false) }

    private func hover(_ value: Bool) {
        inside = value; hoverTask?.cancel(); dismissTask?.cancel()
        if value && !popover.isShown {
            hoverTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, self.inside else { return }
                self.show()
            }
        } else if !value && !pinned {
            dismissTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                guard let self, !self.inside, !self.pinned else { return }
                self.close()
            }
        }
    }

    private func show(fallback: NSView? = nil) {
        guard !popover.isShown, let button = item?.button, let makeContent else { return }
        let buttonFrame = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let visibleAnchor = button.window?.isVisible == true && buttonFrame.width > 0 &&
            NSScreen.screens.contains { $0.frame.contains(buttonFrame) }
        // macOS can overflow a menu item offscreen on narrow displays. Keyboard
        // access then anchors to the app window, never to an invisible (0, 0) item.
        guard visibleAnchor || fallback?.window?.isVisible == true else { return }
        let content = makeContent()
        popover.contentViewController = content
        // Measure before AppKit chooses an anchor, rather than opening a zero-size popover.
        content.view.layoutSubtreeIfNeeded()
        popover.contentSize = content.view.fittingSize
        if visibleAnchor {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else if let fallback {
            let bounds = fallback.bounds
            let rect = CGRect(x: bounds.maxX - 52, y: fallback.isFlipped ? bounds.minY : bounds.maxY - 1, width: 24, height: 1)
            popover.show(relativeTo: rect, of: fallback, preferredEdge: fallback.isFlipped ? .maxY : .minY)
        }
    }
    private func close() {
        hoverTask?.cancel(); dismissTask?.cancel(); pinned = false
        popover.performClose(nil)
    }
    func popoverDidClose(_ notification: Notification) {
        hoverTask?.cancel(); dismissTask?.cancel(); pinned = false; inside = false
        // Release the animated avatar and its WebView while the menu is closed.
        popover.contentViewController = nil
    }
    func remove() {
        generation += 1; close()
        if let tracking { item?.button?.removeTrackingArea(tracking) }; tracking = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
        makeContent = nil; popover.contentViewController = nil
    }
}
