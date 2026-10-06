import Foundation
import UIKit
import VisionKit
import PDFKit
import SwiftUI

@MainActor
class DocumentScannerService_iOS: NSObject, ObservableObject {
    @Published var isScanning = false
    @Published var scannedImages: [UIImage] = []
    @Published var errorMessage: String?

    private var completion: (([UIImage]) -> Void)?

    func startScanning(completion: @escaping ([UIImage]) -> Void) {
        self.completion = completion
        guard VNDocumentCameraViewController.isSupported else {
            errorMessage = "当前设备不支持文档扫描"
            return
        }
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(scanner, animated: true)
    }

    func createPDF(from images: [UIImage]) async -> Data? {
        guard !images.isEmpty else { return nil }
        let pdfDocument = PDFDocument()
        for (index, image) in images.enumerated() {
            guard let pdfPage = PDFPage(image: image) else { continue }
            pdfDocument.insert(pdfPage, at: index)
        }
        return pdfDocument.dataRepresentation()
    }

    func enhanceImage(_ image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(1.1, forKey: kCIInputContrastKey)
        filter?.setValue(0.05, forKey: kCIInputBrightnessKey)
        filter?.setValue(1.2, forKey: kCIInputSaturationKey)
        guard let outputImage = filter?.outputImage,
              let cgImage = CIContext().createCGImage(outputImage, from: outputImage.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }

    func applyDocumentFilter(_ image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return image }
        // 使用 VNDocumentCameraViewController 内置的边缘检测后，
        // 这里可以做进一步的透视矫正、去阴影等
        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(1.15, forKey: kCIInputContrastKey)
        filter?.setValue(0.1, forKey: kCIInputBrightnessKey)
        filter?.setValue(0.8, forKey: kCIInputSaturationKey)
        guard let outputImage = filter?.outputImage,
              let cgImage = CIContext().createCGImage(outputImage, from: outputImage.extent) else { return image }
        return UIImage(cgImage: cgImage)
    }
}

extension DocumentScannerService_iOS: VNDocumentCameraViewControllerDelegate {
    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        Task { @MainActor in
            var images: [UIImage] = []
            for i in 0..<scan.pageCount {
                let image = scan.imageOfPage(at: i)
                if let enhanced = self.applyDocumentFilter(image) {
                    images.append(enhanced)
                } else {
                    images.append(image)
                }
            }
            self.scannedImages = images
            self.completion?(images)
            controller.dismiss(animated: true)
        }
    }

    nonisolated func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        Task { @MainActor in
            self.errorMessage = "扫描失败：\(error.localizedDescription)"
            controller.dismiss(animated: true)
        }
    }

    nonisolated func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        Task { @MainActor in
            controller.dismiss(animated: true)
        }
    }
}

// MARK: - 相机拍照（非文档扫描模式）

@MainActor
class PhotoCameraService: NSObject, ObservableObject {
    @Published var capturedImage: UIImage?
    @Published var errorMessage: String?

    private var completion: ((UIImage?) -> Void)?

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = self
        picker.allowsEditing = false
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(picker, animated: true)
    }
}

extension PhotoCameraService: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    nonisolated func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        Task { @MainActor in
            let image = info[.originalImage] as? UIImage
            self.capturedImage = image
            self.completion?(image)
            picker.dismiss(animated: true)
        }
    }

    nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        Task { @MainActor in
            self.completion?(nil)
            picker.dismiss(animated: true)
        }
    }
}