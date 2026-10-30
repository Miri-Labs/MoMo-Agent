import SwiftUI
import UIKit

/// Keeps per-frame drag updates out of the conversation's state owner.
struct ChatHistoryDrawer<Content: View, Sidebar: View>: View {
    @Binding var isPresented: Bool
    let canOpen: Bool
    let width: CGFloat
    let content: Content
    let sidebar: Sidebar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var translation: CGFloat?
    @State private var settling: Animation = .smooth(duration: 0.25)
    @State private var settlingTarget: Bool?

    init(isPresented: Binding<Bool>, canOpen: Bool, width: CGFloat,
         @ViewBuilder content: () -> Content, @ViewBuilder sidebar: () -> Sidebar) {
        _isPresented = isPresented
        self.canOpen = canOpen
        self.width = width
        self.content = content()
        self.sidebar = sidebar()
    }

    private var visibleWidth: CGFloat {
        HistoryDrawerInteraction.visibleWidth(isPresented: isPresented,
                                             translation: translation ?? 0, width: width)
    }

    private var animation: Animation? {
        if reduceMotion || translation != nil { return nil }
        return settlingTarget == isPresented ? settling : .smooth(duration: 0.25)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            content
                .allowsHitTesting(!isPresented)
                .accessibilityHidden(isPresented)
            Color.black.opacity(0.33 * visibleWidth / max(width, 1))
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(animation, value: visibleWidth)
            HStack(spacing: 0) {
                Spacer(minLength: width)
                Button { isPresented = false } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .accessibilityLabel("关闭菜单")
                .accessibilityIdentifier("sidebar.close")
                .buttonStyle(.plain)
            }
            .ignoresSafeArea(.container, edges: .vertical)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
            sidebar
                .frame(width: width)
                .offset(x: visibleWidth - width)
                .animation(animation, value: visibleWidth)
                .allowsHitTesting(isPresented)
                .accessibilityHidden(!isPresented)
                .accessibilityAction(.escape) { isPresented = false }
        }
        .gesture(HistoryDrawerPan(isEnabled: canOpen || isPresented, isPresented: isPresented,
            changed: { translation = $0 }, ended: finishDrag))
        .onChange(of: isPresented) {
            translation = nil
            if settlingTarget != isPresented { settlingTarget = nil }
        }
        .onChange(of: canOpen) { if !canOpen { translation = nil } }
        .onChange(of: width) { translation = nil }
        .onChange(of: scenePhase) { if scenePhase != .active { translation = nil } }
    }

    private func finishDrag(_ distance: CGFloat, _ velocity: CGFloat, _ cancelled: Bool) {
        let open = cancelled ? isPresented : HistoryDrawerInteraction.shouldOpen(
            isPresented: isPresented, translation: distance, velocity: velocity, width: width)
        let remaining = (open ? width : 0) - visibleWidth
        let initialVelocity = abs(remaining) > 1 && !cancelled ? min(12, max(-12, velocity / remaining)) : 0
        settling = .interpolatingSpring(duration: 0.32, bounce: 0,
                                       initialVelocity: Double(initialVelocity))
        settlingTarget = open
        isPresented = open
        translation = nil
    }
}

enum HistoryDrawerInteraction {
    static func accepts(isPresented: Bool, startX: CGFloat, velocity: CGPoint) -> Bool {
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        return isPresented ? velocity.x < 0 : (0...24).contains(startX) && velocity.x > 0
    }

    static func visibleWidth(isPresented: Bool, translation: CGFloat, width: CGFloat) -> CGFloat {
        min(width, max(0, (isPresented ? width : 0) + translation))
    }

    static func shouldOpen(isPresented: Bool, translation: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        let current = visibleWidth(isPresented: isPresented, translation: translation, width: width)
        return current + velocity * 0.18 > width / 2
    }
}

/// Reject vertical pans before recognition so chat/history scrolling and text interaction keep priority.
private struct HistoryDrawerPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let isPresented: Bool
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        updateUIGestureRecognizer(recognizer, context: context)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isPresented = isPresented
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let distance = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: changed(distance)
        case .ended: ended(distance, recognizer.velocity(in: recognizer.view).x, false)
        case .cancelled, .failed: ended(distance, 0, true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var isPresented = false

        init(converter: CoordinateSpaceConverter) { self.converter = converter }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            let startX = converter.localLocation.x - translation.x
            return HistoryDrawerInteraction.accepts(isPresented: isPresented,
                startX: startX, velocity: pan.velocity(in: pan.view))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // A valid horizontal drawer pan must also work over a native or WebKit scroll view.
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
