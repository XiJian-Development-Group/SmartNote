import SwiftUI
import VisionKit

/// 文档扫描界面（`VNDocumentCameraViewController`）。
///
/// 该控制器自己就是全屏的相机界面，因此这里只是一个薄包装：
/// 负责设置 delegate、把结果交回 `AppState_iOS` 合成 PDF 并入库。
struct DocumentScannerView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        DocumentScannerRepresentable(
            onFinish: { images in
                appState.finishDocumentScan(images: images)
            },
            onCancel: {
                appState.isScanningDocument = false
                dismiss()
            },
            onError: { message in
                appState.errorMessage = message
                appState.showError = true
                appState.isScanningDocument = false
                dismiss()
            }
        )
        .ignoresSafeArea()
    }
}

/// `VNDocumentCameraViewController` 的 SwiftUI 桥接。
private struct DocumentScannerRepresentable: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel, onError: onError)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator

        // 部分设备（以及未授予相机权限时）无法启动扫描器。
        // 这里提前拦截，避免 present 一个永远不出画面的控制器。
        if !VNDocumentCameraViewController.isSupported {
            DispatchQueue.main.async {
                onError("当前设备不支持文档扫描")
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {
        // 扫描器没有需要同步的状态。
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([UIImage]) -> Void
        private let onCancel: () -> Void
        private let onError: (String) -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            onFinish(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            onError("扫描失败：\(error.localizedDescription)")
        }
    }
}