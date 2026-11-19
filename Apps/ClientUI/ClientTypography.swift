import SwiftUI

enum PhoneTextStyle: Equatable {
    case body, navigation, brand, title, heading, subheading, section, transcript, menu, history, metadata, caption, code

    var size: CGFloat {
        #if os(macOS)
        switch self {
        case .body, .transcript: 14
        case .navigation, .menu: 13.5
        case .history, .code: 12.5
        case .brand, .subheading: 15
        case .title, .heading: 19
        case .section: 13.5
        case .metadata: 11.5
        case .caption: 11
        }
        #else
        switch self {
        case .body, .brand, .navigation, .transcript, .section: 16
        case .title, .heading: 22
        case .subheading: 17
        case .menu: 15
        case .history, .code: 14
        case .metadata: 13
        case .caption: 12
        }
        #endif
    }

    /// Paired optical icon size following Sand's F6 typography-glyph scale.
    var iconSize: CGFloat {
        switch self {
        case .title, .heading: 20
        case .subheading, .brand: 18
        case .body, .transcript, .section: 16
        case .navigation, .menu, .history, .code: 14
        case .metadata: 12
        case .caption: 10
        }
    }

    /// Optical tracking: tighter on display/headings, slightly airier on micro-captions.
    var trackingPoints: CGFloat {
        switch self {
        case .title, .heading: -0.32
        case .subheading, .brand: -0.15
        case .section: -0.06
        case .caption: 0.06
        default: 0
        }
    }

    var extraLeading: CGFloat {
        #if os(macOS)
        switch self {
        case .body, .transcript: size * 0.42
        case .code: size * 0.34
        default: 0
        }
        #else
        switch self {
        case .body, .transcript, .code: size * 0.32
        default: 0
        }
        #endif
    }

    var weight: Font.Weight {
        switch self {
        case .heading, .subheading, .section: .medium
        default: .regular
        }
    }

    var relativeStyle: Font.TextStyle {
        switch self {
        case .title, .heading: .title2
        case .subheading: .title3
        case .brand, .section: .body
        case .menu, .history: .subheadline
        case .metadata: .footnote
        case .caption: .caption
        default: .body
        }
    }
}

private struct PhoneTextModifier: ViewModifier {
    let style: PhoneTextStyle
    @ScaledMetric private var size: CGFloat
    @ScaledMetric private var leading: CGFloat

    init(style: PhoneTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeStyle)
        // Reading text keeps 1.5x leading; navigation and labels use the system's compact leading.
        _leading = ScaledMetric(wrappedValue: style.extraLeading,
                                relativeTo: style.relativeStyle)
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: style.weight, design: style == .code ? .monospaced : .default))
            .tracking(style.trackingPoints)
            .lineSpacing(leading)
    }
}

extension View {
    func phoneText(_ style: PhoneTextStyle) -> some View {
        modifier(PhoneTextModifier(style: style))
    }
}

/// Tactile micro-press feedback matching Sand's `--ui-press-scale` (0.98 for cards/pills, 0.94 for icon buttons).
struct MoMoPressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.98
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.0), value: configuration.isPressed)
    }
}
