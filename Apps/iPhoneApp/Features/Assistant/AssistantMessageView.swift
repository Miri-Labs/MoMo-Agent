import SwiftUI

struct AssistantMessageView: View {
    let text: String
    let isUser: Bool
    let accessibilityID: String

    var body: some View {
        if isUser {
            Text(text).phoneText(.body).textSelection(.enabled)
                .accessibilityIdentifier(accessibilityID)
        } else {
            MarkdownReadingView(markdown: text, accessibilityID: accessibilityID).equatable()
        }
    }
}
