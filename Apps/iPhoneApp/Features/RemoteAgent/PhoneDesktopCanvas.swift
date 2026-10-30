import SwiftUI
import UIKit
import MoMoAgentClient
@preconcurrency import WebRTC

/// Native zooming and hit testing keep pointer coordinates in image space, including letterboxing.
struct PhoneDesktopCanvas: UIViewRepresentable {
    let track: RTCVideoTrack
    let size: CGSize
    let controlling: Bool
    let send: (DesktopInput) -> Void

    func makeUIView(context: Context) -> RemoteScrollView {
        let view = RemoteScrollView()
        view.onLayout = { [weak coordinator = context.coordinator] view in coordinator?.layout(in: view) }
        view.delegate = context.coordinator; view.minimumZoomScale = 1; view.maximumZoomScale = 4
        view.showsHorizontalScrollIndicator = false; view.showsVerticalScrollIndicator = false
        view.delaysContentTouches = false
        view.clipsToBounds = true; view.layer.cornerRadius = 12
        let picture = context.coordinator.picture
        picture.contentMode = .scaleAspectFit; picture.isUserInteractionEnabled = true
        picture.accessibilityIdentifier = "desktop.preview"
        picture.accessibilityLabel = "电脑桌面，轻点点击，拖动操作，双指滚动，捏合缩放"
        picture.isAccessibilityElement = true
        picture.accessibilityTraits = .image
        picture.onTap = { [weak coordinator = context.coordinator] point, count in coordinator?.tap(at: point, count: count) }
        view.addSubview(picture)
        context.coordinator.attach(to: view)
        return view
    }
    func updateUIView(_ view: RemoteScrollView, context: Context) {
        let previous = context.coordinator.parent
        if previous.controlling && !controlling {
            context.coordinator.cancelDrag()
        }
        context.coordinator.parent = self
        context.coordinator.attachTrack(track)
        view.panGestureRecognizer.isEnabled = !controlling
        context.coordinator.layout(in: view)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleUIView(_ view: RemoteScrollView, coordinator: Coordinator) { coordinator.cancelDrag(); coordinator.detachTrack() }

    final class RemoteScrollView: UIScrollView {
        var onLayout: ((UIScrollView) -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); onLayout?(self) }
    }

    final class RemoteImageView: UIView {
        let video = RTCMTLVideoView()
        override init(frame: CGRect) {
            super.init(frame: frame)
            video.videoContentMode = .scaleAspectFit; video.isUserInteractionEnabled = false
            addSubview(video)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); video.frame = bounds }
        var onTap: ((CGPoint, Int) -> Void)?
        var touchStart: CGPoint?
        private var hadMultipleTouches = false
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let total = event?.allTouches?.count ?? touches.count
            if total > 1 {
                hadMultipleTouches = true
                touchStart = nil
            } else if !hadMultipleTouches {
                touchStart = touches.first?.location(in: self)
            }
            super.touchesBegan(touches, with: event)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            let remaining = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
            defer { if remaining.isEmpty { hadMultipleTouches = false } }
            guard !hadMultipleTouches, touches.count == 1, event?.allTouches?.count == 1, let touch = touches.first else {
                super.touchesEnded(touches, with: event)
                return
            }
            onTap?(touch.location(in: self), touch.tapCount)
            super.touchesEnded(touches, with: event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            let remaining = (event?.allTouches ?? touches).filter { $0.phase != .ended && $0.phase != .cancelled }
            if remaining.isEmpty { hadMultipleTouches = false; touchStart = nil }
            super.touchesCancelled(touches, with: event)
        }
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: PhoneDesktopCanvas
        let picture = RemoteImageView()
        private var attachedTrack: RTCVideoTrack?
        func attachTrack(_ track: RTCVideoTrack) {
            guard attachedTrack !== track else { return }
            detachTrack(); attachedTrack = track; track.add(picture.video)
        }
        func detachTrack() { attachedTrack?.remove(picture.video); attachedTrack = nil }
        private var dragStarted = false
        private var scrollTranslation = CGPoint.zero
        private var viewportSize = CGSize.zero
        private var sourceSize = CGSize.zero
        init(_ parent: PhoneDesktopCanvas) { self.parent = parent }
        func attach(to view: UIScrollView) {
            let drag = UIPanGestureRecognizer(target: self, action: #selector(drag(_:))); drag.maximumNumberOfTouches = 1
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scroll(_:)))
            scroll.minimumNumberOfTouches = 2; scroll.maximumNumberOfTouches = 2
            let secondary = UITapGestureRecognizer(target: self, action: #selector(secondaryTap(_:)))
            secondary.numberOfTouchesRequired = 2
            for gesture in [drag, scroll, secondary] { gesture.delegate = self; picture.addGestureRecognizer(gesture) }
        }
        func layout(in view: UIScrollView) {
            guard view.bounds.width > 0, view.bounds.height > 0, parent.size.width > 0,
                  (viewportSize != view.bounds.size || sourceSize != parent.size) else { return }
            let previousZoom = view.zoomScale
            let previousCenterNormalized: CGPoint? = if previousZoom > 1, view.contentSize.width > 0, view.contentSize.height > 0 {
                CGPoint(
                    x: max(0, min(1, (view.contentOffset.x + view.contentInset.left + view.bounds.width / 2) / view.contentSize.width)),
                    y: max(0, min(1, (view.contentOffset.y + view.contentInset.top + view.bounds.height / 2) / view.contentSize.height))
                )
            } else { nil }
            viewportSize = view.bounds.size; sourceSize = parent.size
            view.setZoomScale(1, animated: false)
            let scale = min(view.bounds.width / parent.size.width, view.bounds.height / parent.size.height)
            picture.frame = CGRect(origin: .zero, size: CGSize(width: parent.size.width * scale, height: parent.size.height * scale))
            view.contentSize = picture.bounds.size; center(in: view)
            if previousZoom > 1 {
                view.setZoomScale(previousZoom, animated: false)
                center(in: view)
                if let centerNorm = previousCenterNormalized {
                    let minX = -view.contentInset.left
                    let maxX = max(minX, view.contentSize.width - view.bounds.width + view.contentInset.right)
                    let minY = -view.contentInset.top
                    let maxY = max(minY, view.contentSize.height - view.bounds.height + view.contentInset.bottom)
                    view.contentOffset = CGPoint(
                        x: max(minX, min(maxX, centerNorm.x * view.contentSize.width - view.bounds.width / 2)),
                        y: max(minY, min(maxY, centerNorm.y * view.contentSize.height - view.bounds.height / 2))
                    )
                }
            }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(in: scrollView) }
        func center(in view: UIScrollView) {
            view.contentInset = UIEdgeInsets(top: max(0, (view.bounds.height - view.contentSize.height) / 2), left: max(0, (view.bounds.width - view.contentSize.width) / 2), bottom: 0, right: 0)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { parent.controlling }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: max(0, min(1, point.x / max(1, picture.bounds.width))), y: max(0, min(1, point.y / max(1, picture.bounds.height))))
        }
        func emit(_ kind: String, at point: CGPoint) {
            let point = normalized(point); parent.send(.init(kind: kind, x: point.x, y: point.y))
        }
        func tap(at point: CGPoint, count: Int) {
            guard parent.controlling else { return }
            let point = normalized(point)
            var event = DesktopInput(kind: count == 2 ? "double_click" : "click", x: point.x, y: point.y)
            event.click_count = count == 2 ? 2 : 1
            parent.send(event)
        }
        @objc func secondaryTap(_ gesture: UITapGestureRecognizer) { emit("right_click", at: gesture.location(in: picture)) }
        @objc func drag(_ gesture: UIPanGestureRecognizer) {
            let point = gesture.location(in: picture)
            switch gesture.state {
            case .began:
                let movement = gesture.translation(in: picture)
                emit("mouse_down", at: picture.touchStart ?? CGPoint(x: point.x - movement.x, y: point.y - movement.y)); dragStarted = true
                emit("mouse_move", at: point)
            case .changed: if dragStarted { emit("mouse_move", at: point) }
            case .ended: if dragStarted { emit("mouse_up", at: point); dragStarted = false }
            case .cancelled, .failed: cancelDrag()
            default: break
            }
        }
        @objc func scroll(_ gesture: UIPanGestureRecognizer) { handleScroll(gesture) }
        func handleScroll(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { scrollTranslation = .zero }
            guard gesture.state == .began || gesture.state == .changed else { return }
            let next = gesture.translation(in: picture), point = normalized(gesture.location(in: picture))
            let scale = parent.size.width / max(1, picture.bounds.width)
            let dx = Int(max(-1000, min(1000, (next.x - scrollTranslation.x) * scale)))
            let dy = Int(max(-1000, min(1000, (next.y - scrollTranslation.y) * scale)))
            if dx != 0 || dy != 0 { parent.send(.init(kind: "scroll", x: point.x, y: point.y, delta: dy, delta_x: dx)); scrollTranslation = next }
        }
        func cancelDrag() {
            if dragStarted { parent.send(.init(kind: "reset")); dragStarted = false }
        }
    }
}
