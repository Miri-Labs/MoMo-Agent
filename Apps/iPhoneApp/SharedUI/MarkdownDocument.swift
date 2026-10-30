import Foundation

/// Foundation owns Markdown syntax; this value only maps its block semantics to reading layout.
struct MarkdownDocument {
    struct Block: Identifiable {
        let id: Int
        let text: AttributedString
        let headingLevel: Int?
        let listDepth: Int
        let listMarker: String?
        let isQuote: Bool
        let isCode: Bool

        var plainText: String { String(text.characters) }
    }

    let blocks: [Block]

    init(_ markdown: String) throws {
        let attributed = try AttributedString(markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
        var result: [Block] = []
        var seenListItems = Set<Int>()
        // Slicing by this attribute keeps inline emphasis and links in the same paragraph.
        for (intent, range) in attributed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var heading: Int?
            var listDepth = 0
            var item: PresentationIntent.IntentType?
            var ordered = false
            var foundNearestList = false
            var quote = false
            var code = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .listItem: if item == nil { item = component }
                case .orderedList, .unorderedList:
                    listDepth += 1
                    if !foundNearestList {
                        ordered = component.kind == .orderedList
                        foundNearestList = true
                    }
                case .blockQuote: quote = true
                case .codeBlock: code = true
                default: break
                }
            }
            var marker: String?
            if let item, seenListItems.insert(item.identity).inserted,
               case .listItem(let ordinal) = item.kind {
                marker = ordered ? "\(ordinal)." : "•"
            }
            result.append(Block(id: components.first?.identity ?? 0,
                text: AttributedString(attributed[range]), headingLevel: heading,
                listDepth: listDepth, listMarker: marker, isQuote: quote, isCode: code))
        }
        blocks = result
    }
}
