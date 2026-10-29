import SwiftUI

extension View {
    @ViewBuilder func composerSurface() -> some View {
        background(MoMoPalette.canvas, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(MoMoPalette.line, lineWidth: 0.75)
            }
    }
}
