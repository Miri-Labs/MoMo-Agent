import SwiftUI
import UIKit
import MoMoArchive

/// UIKit supplies the activity completion boundary needed to safely remove shared file URLs.
struct ArchiveShareSheet: UIViewControllerRepresentable {
    let artifact: ArchiveExport
    let completion: @MainActor (String?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: artifact.fileURLs, applicationActivities: nil)
        let completed = completion
        controller.completionWithItemsHandler = { _, _, _, error in
            let message = error.map { String(localized: "分享未完成：\($0.localizedDescription)") }
            Task { @MainActor in completed(message) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
