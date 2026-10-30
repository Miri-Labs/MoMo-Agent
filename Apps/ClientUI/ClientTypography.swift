import SwiftUI

enum PhoneTextStyle: Equatable {
    case body, navigation, brand, title, heading, subheading, section, transcript, menu, history, metadata, caption, code

    var size: CGFloat {
        #if os(macOS)
        switch self {
        case .body, .transcript: 15
        case .navigation, .menu, .history, .code: 13
        case .brand, .subheading: 16
        case .title, .heading: 22
        case .section: 14
        case .metadata: 12
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

    var extraLeading: CGFloat {
        switch self {
        case .body, .transcript, .code: size * 0.3
        default: 0
        }
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
            .lineSpacing(leading)
    }
}

extension View {
    func phoneText(_ style: PhoneTextStyle) -> some View {
        modifier(PhoneTextModifier(style: style))
    }
}
