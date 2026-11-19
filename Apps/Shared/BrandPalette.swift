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

    /// Outer gray shell & sidebar (#F2F2F4 Light / #0D0D0F Dark).
    static let sidebar: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 13.0 / 255, green: 13.0 / 255, blue: 15.0 / 255, alpha: 1.0)
                : NSColor(srgbRed: 242.0 / 255, green: 242.0 / 255, blue: 244.0 / 255, alpha: 1.0)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 13.0 / 255, green: 13.0 / 255, blue: 15.0 / 255, alpha: 1.0)
                : UIColor(red: 242.0 / 255, green: 242.0 / 255, blue: 244.0 / 255, alpha: 1.0)
        })
        #endif
    }()

    /// Floating white stage card & editorial document pane (#FFFFFF Light / #171719 Dark).
    static let pane: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 23.0 / 255, green: 23.0 / 255, blue: 25.0 / 255, alpha: 1.0)
                : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        })
        #else
        paper
        #endif
    }()

    /// Subtle secondary split sub-pane (#F8F8F8 Light / #121212 Dark).
    static let subpane: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark
                ? NSColor(srgbRed: 18.0 / 255, green: 18.0 / 255, blue: 18.0 / 255, alpha: 1.0)
                : NSColor(srgbRed: 248.0 / 255, green: 248.0 / 255, blue: 248.0 / 255, alpha: 1.0)
        })
        #else
        canvas
        #endif
    }()

    static var tertiaryInk: Color { ink.opacity(0.42) }
    static var hoverFill: Color { ink.opacity(0.05) }
    static var activeFill: Color { ink.opacity(0.085) }
    static var borderSubtle: Color { ink.opacity(0.065) }
    static var borderDefault: Color { ink.opacity(0.10) }
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
            .background {
                // Apply shadow ONLY to the static card shape (never to `content`), avoiding offscreen alpha compositing passes on every frame.
                shape
                    .fill(MoMoPalette.paper)
                    .shadow(
                        color: isDark || shadowStrength <= 0 ? .clear : Color.black.opacity(0.035 * shadowStrength),
                        radius: 7,
                        x: 0,
                        y: 2
                    )
            }
            .overlay {
                shape.strokeBorder(
                    isFocused
                        ? MoMoPalette.borderFocus
                        : (isDark ? Color.white.opacity(0.085) : MoMoPalette.borderDefault),
                    lineWidth: isFocused ? 0.85 : 0.5
                )
                .allowsHitTesting(false)
            }
    }
}

private struct SandInsetStageModifier: ViewModifier {
    let cornerRadius: CGFloat
    var fill: Color = MoMoPalette.pane
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .background {
                // Keep the ambient shadow strictly on the static backdrop shape so live-scrolling
                // WKWebView / NSTableView children inside `content` never trigger offscreen shadow passes.
                shape
                    .fill(fill)
                    .shadow(
                        color: isDark ? .clear : Color.black.opacity(0.032),
                        radius: 10,
                        x: 0,
                        y: 3
                    )
            }
            .overlay {
                shape.strokeBorder(
                    isDark ? Color.white.opacity(0.085) : Color.black.opacity(0.07),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
            }
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

    /// Floating white workspace stage card framed against the outer gray desktop shell.
    func sandInsetStage(cornerRadius: CGFloat = 16, fill: Color = MoMoPalette.pane) -> some View {
        modifier(SandInsetStageModifier(cornerRadius: cornerRadius, fill: fill))
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
