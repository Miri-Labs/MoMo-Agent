import SwiftUI

struct DesktopNotchSurface<Content: View>: View {
    let expanded: Bool
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: expanded ? 24 : 12,
            bottomTrailingRadius: expanded ? 24 : 12,
            style: .continuous
        )
        VStack(spacing: 0) { content }
            // AppKit owns the resize animation. The compact content must remain
            // at the top of the still-large window throughout its collapse.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(.white)
            .background {
                if expanded && !reduceTransparency {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: Color(red: 0.03, green: 0.03, blue: 0.04), location: 0.16),
                            .init(color: Color(red: 0.075, green: 0.075, blue: 0.088), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    Color.black
                }
            }
            .clipShape(shape)
            .overlay {
                if expanded {
                    shape.strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .white.opacity(0.08), location: 0.25),
                                .init(color: .white.opacity(0.15), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
    }
}
