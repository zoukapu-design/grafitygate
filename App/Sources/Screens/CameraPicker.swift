import SwiftUI
import UIKit

/// カメラで 1 枚撮る。現地で確かめるため、写真アプリからは選ばせない（前に撮った写真で入れないように）。
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// カメラが使えないとき（シミュレーターなど）の代わりの表示
struct CameraUnavailableNote: View {
    var body: some View {
        NoticeText(text: "この端末ではカメラが使えません。GATE を作る・入るには、iPhone のカメラで現地を写す必要があります。")
    }
}

/// 写真から特徴を作る（重いので、メインの列の外で）
func makePrint(from image: UIImage) async throws -> [Float] {
    try await Task.detached(priority: .userInitiated) {
        try FeaturePrint.make(from: image)
    }.value
}
