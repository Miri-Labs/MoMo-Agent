import Foundation
import CoreGraphics

/// Global screen coordinates; the physical camera housing is never a content area.
struct DesktopNotchLayout: Equatable {
    let screen: CGRect
    let notch: CGRect
    init?(screen: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?) {
        guard safeTop > 0, let left, let right, right.minX > left.maxX,
              left.maxX > screen.minX, right.minX < screen.maxX else { return nil }
        self.screen = screen
        notch = CGRect(x: left.maxX, y: screen.maxY - safeTop, width: right.minX - left.maxX, height: safeTop)
    }
    var topPadding: CGFloat { notch.height }
    var expandedWidth: CGFloat { min(screen.width - 24, max(360, notch.width + 100)) }
    var compactFrame: CGRect {
        frame(width: notch.width + 88, height: notch.height)
    }
    func expandedFrame(contentHeight: CGFloat) -> CGRect {
        frame(width: expandedWidth, height: min(contentHeight + topPadding, screen.height - 32))
    }
    private func frame(width: CGFloat, height: CGFloat) -> CGRect {
        let center = notch.midX
        let x = min(max(center - width / 2, screen.minX + 12), screen.maxX - width - 12)
        return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
    }
}
