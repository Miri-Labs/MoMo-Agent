import SwiftUI

/// Quiet grouped rows using the existing phone palette and native navigation.
struct PhoneSettingsSurface<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        VStack(spacing: 0) { content }
            .background(MoMoPalette.paper, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(contrast == .increased ? MoMoPalette.muted : MoMoPalette.line, lineWidth: 1)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

struct PhoneSettingsLinkRow: View {
    let title: String
    var symbol: String?
    var value: String?
    var disclosure = true

    var body: some View {
        HStack(spacing: 12) {
            if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .regular)).frame(width: 20).accessibilityHidden(true) }
            Text(LocalizedStringKey(title)).phoneText(.body)
                .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Spacer(minLength: 8)
            if let value {
                Text(LocalizedStringKey(value)).phoneText(.metadata)
                    .foregroundStyle(MoMoPalette.muted).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if disclosure {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MoMoPalette.muted).accessibilityHidden(true)
            }
        }
        .foregroundStyle(MoMoPalette.ink)
        .padding(.horizontal, 16).padding(.vertical, 10).frame(minHeight: 52).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PhoneSettingsValueRow: View {
    let title: String
    let value: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(title)).phoneText(.body)
            Spacer(minLength: 0)
            value.phoneText(.metadata).foregroundStyle(MoMoPalette.muted).multilineTextAlignment(.trailing)
        }.frame(minHeight: 44).accessibilityElement(children: .combine)
    }
}

struct PhoneSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).phoneText(.metadata).fontWeight(.medium)
                .foregroundStyle(MoMoPalette.muted).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            content
        }
    }
}

struct PhoneActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.phoneText(.body)
            .foregroundStyle(MoMoPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}
