import Foundation
import UniformTypeIdentifiers
import PDFKit
import Vision
import SwiftUI

@MainActor
class FileScannerService_iOS: ObservableObject {
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var errorMessage: String?

    enum StorageMode { case copy, reference }

    func scanFiles(urls: [URL], storageMode: StorageMode = .copy) async -> [StudyMaterial] {
        isScanning = true
        defer { isScanning = false }

        var materials: [StudyMaterial] = []
        let total = urls.count

        for index in urls.indices {
            progress = Double(index) / Double(total)
            if let material = await processFile(urls[index], storageMode: storageMode) {
                materials.append(material)
            }
        }
        progress = 1.0
        return materials
    }

    func scanDirectory(at url: URL, storageMode: StorageMode = .copy) async -> [StudyMaterial] {
        isScanning = true
        defer { isScanning = false }

        var materials: [StudyMaterial] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var urlsToProcess: [URL] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            urlsToProcess.append(fileURL)
        }

        let total = urlsToProcess.count
        for index in urlsToProcess.indices {
            progress = Double(index) / Double(total)
            if let material = await processFile(urlsToProcess[index], storageMode: storageMode) {
                materials.append(material)
            }
        }
        progress = 1.0
        return materials
    }

    private func processFile(_ url: URL, storageMode: StorageMode) async -> StudyMaterial? {
        // 文档选择器（`fileImporter`）返回的是**安全作用域 URL**：在调用
        // `startAccessingSecurityScopedResource()` 之前，任何读取/拷贝都会被系统
        // 拒绝（报 "Operation not permitted" 或 "The file couldn’t be opened"）。
        //
        // 这里必须自己开访问权，而不是依赖调用方——调用方（视图层）的
        // `defer { stopAccessing... }` 会在把 URL 交回来之前就释放掉访问权。
        // macOS 版的 `FileScannerService.processFile` 就是这么处理的。
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // 即使拿到访问权，文件也可能已被用户在"文件"App 里移动/删除。
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "无法读取文件：\(url.lastPathComponent)"
            return nil
        }

        let fileName = url.lastPathComponent
        let fileType = detectFileType(from: url)

        let destinationURL: URL
        if storageMode == .copy {
            let storage = StorageService.shared
            let materialsDir = storage.getMaterialsDirectory()
            let uniqueName = generateUniqueName(for: fileName, in: materialsDir)
            destinationURL = materialsDir.appendingPathComponent(uniqueName)

            do {
                try FileManager.default.copyItem(at: url, to: destinationURL)
            } catch {
                errorMessage = "复制文件失败：\(error.localizedDescription)"
                return nil
            }
        } else {
            destinationURL = url
        }

        var content = ""
        var extractedText: String?

        switch fileType {
        case .pdf:
            extractedText = await extractPDFText(from: destinationURL)
            content = extractedText ?? ""
        case .text, .markdown:
            content = (try? String(contentsOf: destinationURL)) ?? ""
        case .word, .powerpoint, .document:
            // Office 文档不解析正文；保留占位说明，后续由 AI/用户补充。
            content = "[文档文件：\(fileName)]"
        case .image:
            extractedText = await OCRService_iOS.shared.recognizeText(from: destinationURL)
            content = extractedText ?? ""
        case .video, .audio:
            content = "[媒体文件：\(fileName)]"
        case .other:
            content = "[未知文件：\(fileName)]"
        }

        let material = StudyMaterial(
            name: fileName,
            type: fileType,
            localURL: destinationURL,
            content: content,
            extractedText: extractedText
        )
        return material
    }

    private func detectFileType(from url: URL) -> MaterialType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "txt", "md", "markdown": return .markdown
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tiff": return .image
        case "doc", "docx", "ppt", "pptx", "xls", "xlsx": return .document
        case "mp4", "mov", "avi", "mkv": return .video
        case "mp3", "wav", "m4a", "aac": return .audio
        default: return .other
        }
    }

    private func extractPDFText(from url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            Task.detached {
                guard let document = PDFDocument(url: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                var fullText = ""
                for i in 0..<document.pageCount {
                    if let page = document.page(at: i), let text = page.string {
                        fullText += text + "\n"
                    }
                }
                continuation.resume(returning: fullText.isEmpty ? nil : fullText)
            }
        }
    }

    private func generateUniqueName(for name: String, in directory: URL) -> String {
        let fileManager = FileManager.default
        var uniqueName = name
        var counter = 1
        while fileManager.fileExists(atPath: directory.appendingPathComponent(uniqueName).path) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            uniqueName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            counter += 1
        }
        return uniqueName
    }
}
