import SwiftUI

extension View {
    func phonePageSurface() -> some View {
        phoneText(.body)
            .foregroundStyle(MoMoPalette.ink)
            .tint(MoMoPalette.ink)
            .background(MoMoPalette.canvas)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}
