import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ChatCameraFailure: String, Identifiable {
    case unavailable, denied, restricted
    var id: String { rawValue }
    var message: String {
        switch self {
        case .unavailable: String(localized: "这台设备目前无法使用相机，可以从照片图库添加图片。")
        case .denied: String(localized: "请在系统设置中允许 MoMo Agent 使用相机。")
        case .restricted: String(localized: "系统限制了相机访问，可以从照片图库添加图片。")
        }
    }
}

/// Keep the system camera's capture, retake and confirmation controls.
struct ChatCameraPicker: UIViewControllerRepresentable {
    let completion: (Result<UIImage?, ChatAttachmentImportError>) -> Void

    static func authorizationFailure() async -> ChatCameraFailure? {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return nil
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? nil : .denied
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .unavailable
        }
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private var completion: ((Result<UIImage?, ChatAttachmentImportError>) -> Void)?
        init(completion: @escaping (Result<UIImage?, ChatAttachmentImportError>) -> Void) { self.completion = completion }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(.success(nil)) }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { finish(.failure(.unreadable)); return }
            finish(.success(image))
        }

        private func finish(_ result: Result<UIImage?, ChatAttachmentImportError>) {
            let callback = completion
            completion = nil
            callback?(result)
        }
    }
}
