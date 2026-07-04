import Foundation
import AppKit
import PDFKit

/// Simple thumbnail provider with an in-memory cache. Generates thumbnails for images and PDFs lazily.
final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private var cache: [UUID: NSImage] = [:]
    private let queue = DispatchQueue(label: "ThumbnailProvider.queue", qos: .userInitiated)

    private init() {}

    func thumbnail(for material: StudyMaterial, size: CGSize = CGSize(width: 64, height: 64), completion: @escaping (NSImage?) -> Void) {
        if let cached = cache[material.id] {
            completion(cached)
            return
        }

        queue.async { [weak self] in
            var image: NSImage?

            if let url = material.localURL {
                switch material.type {
                case .image:
                    image = NSImage(contentsOf: url)
                case .pdf:
                    if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                        image = page.thumbnail(of: size, for: .mediaBox)
                    }
                default:
                    break
                }
            }

            // fallback: small icon based on file type
            if image == nil {
                let fileTypeStr = self?.fileType(for: material) ?? ""
                let icon = NSWorkspace.shared.icon(forFileType: fileTypeStr)
                icon.size = size
                image = icon
            }

            if let img = image {
                self?.cache[material.id] = img
            }

            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func fileType(for material: StudyMaterial) -> String {
        if let url = material.localURL {
            return url.pathExtension
        }
        switch material.type {
        case .pdf: return "pdf"
        case .image: return "png"
        case .text: return "txt"
        default: return "" 
        }
    }
}
