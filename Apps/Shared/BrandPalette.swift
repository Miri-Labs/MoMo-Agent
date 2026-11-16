import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum MoMoPalette {
    #if os(watchOS)
    // Keep the Watch dark even when its asset compiler omits named-color luminosity variants.
    static let canvas = Color(.sRGB, red: 22.0 / 255, green: 21.0 / 255, blue: 18.0 / 255)
    static let surface = Color(.sRGB, red: 48.0 / 255, green: 44.0 / 255, blue: 38.0 / 255)
    static let ink = Color(.sRGB, red: 243.0 / 255, green: 238.0 / 255, blue: 229.0 / 255)
    #else
    static let canvas = Color("PhoneBackground")
    static let surface = Color("PhoneSurface")
    static let ink = Color("PhoneInk")
    static let muted = Color("PhoneMuted")
    static let line = Color("PhoneLine")
    static let paper = Color("PhonePaper")
    static let success = Color("PhoneSuccess")
    static let successBackground = Color("PhoneSuccessBackground")
    static let failure = Color("PhoneFailure")
    static let failureBackground = Color("PhoneFailureBackground")

    /// Deepest recessed rail layer (#F4F4F3 Light / #0E0E0E Dark), keeping main canvas elevated above sidebar.
    static var sidebar: Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 14.0 / 255, green: 14.0 / 255, blue: 14.0 / 255, alpha: 1.0)
                : NSColor(srgbRed: 244.0 / 255, green: 244.0 / 255, blue: 243.0 / 255, alpha: 1.0)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 14.0 / 255, green: 14.0 / 255, blue: 14.0 / 255, alpha: 1.0)
                : UIColor(red: 244.0 / 255, green: 244.0 / 255, blue: 243.0 / 255, alpha: 1.0)
        })
        #endif
    }

    static var hoverFill: Color { ink.opacity(0.05) }
    static var activeFill: Color { ink.opacity(0.085) }
    static var borderSubtle: Color { ink.opacity(0.065) }
    static var borderDefault: Color { ink.opacity(0.105) }
    static var borderStrong: Color { ink.opacity(0.18) }
    static var borderFocus: Color { ink.opacity(0.28) }
    #endif
}

#if !os(watchOS)
private struct MoMoElevatedCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    var isFocused: Bool = false
    var shadowStrength: CGFloat = 1.0
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(MoMoPalette.paper, in: shape)
            .overlay {
                shape.strokeBorder(
                    isFocused
                        ? MoMoPalette.borderFocus
                        : (isDark ? Color.white.opacity(0.09) : MoMoPalette.borderDefault),
                    lineWidth: isFocused ? 0.85 : 0.5
                )
                .allowsHitTesting(false)
            }
            // Sand elevation law: Light mode uses a single lightweight shadow; Dark mode uses 0% black shadow.
            .shadow(
                color: isDark || shadowStrength <= 0 ? .clear : Color.black.opacity(0.038 * shadowStrength),
                radius: 7,
                x: 0,
                y: 2
            )
    }
}

extension View {
    func momoElevatedCard(
        cornerRadius: CGFloat,
        isFocused: Bool = false,
        shadowStrength: CGFloat = 1.0
    ) -> some View {
        modifier(MoMoElevatedCardModifier(
            cornerRadius: cornerRadius,
            isFocused: isFocused,
            shadowStrength: shadowStrength
        ))
    }

    /// Zero-mask top/bottom fade overlay that preserves 120fps native NSScrollView layer compositing.
    func momoScrollEdgeFade(top: CGFloat = 14, bottom: CGFloat = 0, surface: Color = MoMoPalette.canvas) -> some View {
        overlay(alignment: .top) {
            if top > 0 {
                LinearGradient(
                    colors: [surface, surface.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if bottom > 0 {
                LinearGradient(
                    colors: [surface.opacity(0), surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
#endif
