import SwiftUI

/// Structured representation of an AI recording summary styled after Siri Recap cards.
nonisolated struct TranscriptRecapContent: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: Int
        let text: AttributedString
        let isBullet: Bool
        let listMarker: String?
        let isQuote: Bool
        let isCode: Bool
    }

    struct Section: Identifiable, Equatable, Sendable {
        let id: Int
        let heading: String?
        let items: [Item]
    }

    let title: String?
    let lead: AttributedString?
    let sections: [Section]

    var isEmpty: Bool {
        title == nil && lead == nil && sections.isEmpty
    }

    var totalItemCount: Int {
        sections.reduce(0) { $0 + $1.items.count }
    }

    @MainActor
    static func parse(_ markdown: String) -> TranscriptRecapContent {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TranscriptRecapContent(title: nil, lead: nil, sections: [])
        }
        guard case .success(let document) = MarkdownDocument.cached(trimmed), !document.blocks.isEmpty else {
            return TranscriptRecapContent(title: nil, lead: AttributedString(trimmed), sections: [])
        }

        let blocks = document.blocks
        var index = 0
        var title: String?
        var lead: AttributedString?

        let first = blocks[0]
        if first.headingLevel != nil {
            let text = first.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { title = text }
            index = 1
            if index < blocks.count, isPlainParagraph(blocks[index]) {
                lead = blocks[index].text
                index += 1
            }
        } else if isPlainParagraph(first) {
            let raw = first.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if blocks.count > 1 {
                if raw.count <= 38 {
                    title = raw
                    index = 1
                    if index < blocks.count, isPlainParagraph(blocks[index]) {
                        lead = blocks[index].text
                        index += 1
                    }
                } else if let split = splitHeadlineAndLead(raw) {
                    title = split.headline
                    lead = AttributedString(split.remainder)
                    index = 1
                } else {
                    lead = first.text
                    index = 1
                }
            } else {
                if let split = splitHeadlineAndLead(raw) {
                    title = split.headline
                    lead = AttributedString(split.remainder)
                } else {
                    lead = first.text
                }
                index = 1
            }
        }

        var sections: [Section] = []
        var currentHeading: String?
        var currentItems: [Item] = []
        var sectionID = 0

        func flushSection() {
            if currentHeading != nil || !currentItems.isEmpty {
                sections.append(Section(id: sectionID, heading: currentHeading, items: currentItems))
                sectionID += 1
                currentHeading = nil
                currentItems = []
            }
        }

        while index < blocks.count {
            let block = blocks[index]
            if block.headingLevel != nil {
                flushSection()
                let headingText = block.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                currentHeading = headingText.isEmpty ? nil : headingText
            } else {
                currentItems.append(Item(
                    id: block.id,
                    text: block.text,
                    isBullet: block.listDepth > 0,
                    listMarker: block.listMarker,
                    isQuote: block.isQuote,
                    isCode: block.isCode
                ))
            }
            index += 1
        }
        flushSection()

        return TranscriptRecapContent(title: title, lead: lead, sections: sections)
    }

    @MainActor
    private static func isPlainParagraph(_ block: MarkdownDocument.Block) -> Bool {
        block.headingLevel == nil && block.listDepth == 0 && !block.isQuote && !block.isCode
    }

    private static func splitHeadlineAndLead(_ text: String) -> (headline: String, remainder: String)? {
        let terminators: [Character] = ["。", "！", "？", "!", "?"]
        var splitIndex: String.Index?
        for idx in text.indices {
            let ch = text[idx]
            if terminators.contains(ch) {
                let next = text.index(after: idx)
                splitIndex = next
                break
            }
            if ch == "." {
                let next = text.index(after: idx)
                if next < text.endIndex, text[next] == " " {
                    splitIndex = next
                    break
                }
            }
        }
        guard let splitIndex else { return nil }
        let headline = String(text[..<splitIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(text[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard headline.count >= 6, headline.count <= 38, !remainder.isEmpty else { return nil }
        return (headline, remainder)
    }
}

#if !os(watchOS)
/// Floating white editorial card surface framed against the soft gray canvas (`MoMoPalette.sidebar`).
private struct RecapCardSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape
                    .fill(MoMoPalette.paper)
                    .shadow(
                        color: isDark ? .clear : Color.black.opacity(0.055),
                        radius: 18,
                        x: 0,
                        y: 5
                    )
            }
            .overlay {
                if isDark {
                    shape.strokeBorder(Color.white.opacity(0.075), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func recapCardSurface(cornerRadius: CGFloat = 28) -> some View {
        modifier(RecapCardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

/// Renders structured `TranscriptRecapContent` in the Siri Recap typographic hierarchy.
struct TranscriptRecapBody: View, Equatable {
    let content: TranscriptRecapContent
    var compact: Bool = true
    var accessibilityID: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var compactTitleSize: CGFloat = 23
    @ScaledMetric(relativeTo: .title2) private var fullTitleSize: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var sectionHeaderSize: CGFloat = 11.5

    nonisolated static func == (lhs: TranscriptRecapBody, rhs: TranscriptRecapBody) -> Bool {
        lhs.content == rhs.content && lhs.compact == rhs.compact && lhs.accessibilityID == rhs.accessibilityID
    }

    var body: some View {
        let visibleSections = resolvedSections
        let hiddenItems = compact ? max(0, content.totalItemCount - visibleSections.reduce(0) { $0 + $1.items.count }) : 0

        VStack(alignment: .leading, spacing: 0) {
            if let title = content.title {
                Text(title)
                    .font(.system(size: compact ? compactTitleSize : fullTitleSize, weight: .bold))
                    .tracking(-0.42)
                    .lineSpacing(2.5)
                    .foregroundStyle(MoMoPalette.ink)
                    .lineLimit(compact && !dynamicTypeSize.isAccessibilitySize ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }

            if let lead = content.lead {
                Text(lead)
                    .font(.system(size: bodySize, weight: .regular))
                    .lineSpacing(5)
                    .foregroundStyle(MoMoPalette.ink.opacity(0.90))
                    .lineLimit(compact && !dynamicTypeSize.isAccessibilitySize ? 4 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, content.title == nil ? 0 : 11)
            }

            ForEach(visibleSections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    if let heading = section.heading {
                        Text(heading.uppercased())
                            .font(.system(size: sectionHeaderSize, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(MoMoPalette.ink.opacity(0.76))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 20)
                            .padding(.bottom, 1)
                            .accessibilityAddTraits(.isHeader)
                    }

                    ForEach(section.items) { item in
                        recapItemRow(item)
                    }
                }
                .padding(.top, section.heading == nil && (content.title != nil || content.lead != nil || section.id != visibleSections.first?.id) ? 14 : 0)
            }

            if hiddenItems > 0 {
                Text("还有 \(hiddenItems) 条要点")
                    .phoneText(.caption)
                    .foregroundStyle(MoMoPalette.muted)
                    .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OptionalAccessibilityID(id: accessibilityID))
    }

    @ViewBuilder
    private func recapItemRow(_ item: TranscriptRecapContent.Item) -> some View {
        if item.isBullet {
            HStack(alignment: .top, spacing: 12) {
                if let marker = item.listMarker, marker != "•" {
                    Text(marker)
                        .font(.system(size: 13.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(MoMoPalette.muted.opacity(0.65))
                        .padding(.top, 2)
                } else {
                    Circle()
                        .fill(MoMoPalette.muted.opacity(0.30))
                        .frame(width: 5.5, height: 5.5)
                        .padding(.top, 8.5)
                        .accessibilityHidden(true)
                }
                Text(item.text)
                    .font(.system(size: bodySize, weight: .regular))
                    .lineSpacing(4.5)
                    .foregroundStyle(MoMoPalette.ink.opacity(0.90))
                    .lineLimit(compact && !dynamicTypeSize.isAccessibilitySize ? 3 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if item.isQuote {
            Text(item.text)
                .font(.system(size: bodySize, weight: .regular))
                .lineSpacing(4.5)
                .foregroundStyle(MoMoPalette.muted)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(MoMoPalette.line)
                        .frame(width: 2.5)
                        .accessibilityHidden(true)
                }
                .fixedSize(horizontal: false, vertical: true)
        } else if item.isCode {
            Text(item.text)
                .phoneText(.code)
                .foregroundStyle(MoMoPalette.ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MoMoPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(item.text)
                .font(.system(size: bodySize, weight: .regular))
                .lineSpacing(5)
                .foregroundStyle(MoMoPalette.ink.opacity(0.90))
                .lineLimit(compact && !dynamicTypeSize.isAccessibilitySize ? 4 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resolvedSections: [TranscriptRecapContent.Section] {
        guard compact else { return content.sections }
        var remaining = 6
        var result: [TranscriptRecapContent.Section] = []
        for section in content.sections {
            guard result.count < 2 else { break }
            if section.items.isEmpty {
                if section.heading != nil {
                    result.append(section)
                }
                continue
            }
            guard remaining > 0 else { break }
            let slice = Array(section.items.prefix(remaining))
            remaining -= slice.count
            result.append(TranscriptRecapContent.Section(id: section.id, heading: section.heading, items: slice))
        }
        return result
    }
}

private struct OptionalAccessibilityID: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id {
            content.accessibilityIdentifier(id)
        } else {
            content
        }
    }
}
#endif

/// The phone timeline's presentation, shared with the desktop source adapter.
struct ClientTranscriptRow<Detail: View>: View {
    let time: String
    let preview: String
    let status: String?
    let connected: Bool
    let isFinal: Bool
    var continuesFromPrevious = false
    var bottomSpacing: CGFloat = 26
    @ViewBuilder let detail: () -> Detail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Rectangle().fill(MoMoPalette.borderDefault).frame(width: 0.75, height: 17)
                    .opacity(continuesFromPrevious ? 1 : 0)
                Circle().strokeBorder(MoMoPalette.muted.opacity(0.85), lineWidth: 1.25)
                    .background(isFinal ? Color.clear : MoMoPalette.ink, in: Circle()).frame(width: 7.5, height: 7.5)
                if connected { Rectangle().fill(MoMoPalette.borderDefault).frame(width: 0.75) }
            }.frame(width: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                if status == nil {
                    HStack { Text(time).phoneText(.menu).monospacedDigit(); Spacer(minLength: 8); state }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text(time).phoneText(.menu).monospacedDigit(); Spacer(minLength: 8); state }
                        VStack(alignment: .leading, spacing: 4) { Text(time).phoneText(.menu).monospacedDigit(); state }
                    }
                }
                detail()
                if !preview.isEmpty {
                    Text(preview).phoneText(.menu).foregroundStyle(MoMoPalette.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.top, 10).padding(.bottom, bottomSpacing)
        }
        .foregroundStyle(MoMoPalette.ink)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true).contentShape(Rectangle())
    }

    @ViewBuilder private var state: some View {
        if let status { Text(status).phoneText(.caption).foregroundStyle(MoMoPalette.muted) }
        else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(MoMoPalette.muted) }
    }
}
