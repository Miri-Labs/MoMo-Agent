import SwiftUI

struct DesktopNotchSurface<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            // AppKit owns the resize animation. The compact content must remain
            // at the top of the still-large window throughout its collapse.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white).background(.black)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: expanded ? 26 : 12,
                                             bottomTrailingRadius: expanded ? 26 : 12))
            .ignoresSafeArea()
    }
}
