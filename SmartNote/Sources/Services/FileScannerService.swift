import Foundation
import AppKit
import PDFKit

actor FileScannerService {
    private let supportedExtensions: Set<String> = [
        "pdf", "doc", "docx", "ppt", "pptx",
        "png", "jpg", "jpeg", "gif", "bmp", "tiff",
        "txt", "md"
    ]
    
    func scanFiles(urls: [URL], storageMode: MaterialStorageMode = .copy) async -> [StudyMaterial] {
        var materials: [StudyMaterial] = []
        
        for url in urls {
            let material = await processFile(at: url, storageMode: storageMode)
            if let material = material {
                materials.append(material)
            }
        }
        
        return materials
    }
    
    func scanDirectory(at url: URL, storageMode: MaterialStorageMode = .copy) async -> [StudyMaterial] {
        var materials: [StudyMaterial] = []
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return materials
        }
        
        for case let fileURL as URL in enumerator {
            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }
            
            let material = await processFile(at: fileURL, storageMode: storageMode)
            if let material = material {
                materials.append(material)
            }
        }
        
        return materials
    }
    
    func scanCommonDirectories(storageMode: MaterialStorageMode = .copy) async -> [StudyMaterial] {
        var materials: [StudyMaterial] = []
        let fileManager = FileManager.default
        
        let directories = [
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
        
        for directory in directories {
            let foundMaterials = await scanDirectory(at: directory, storageMode: storageMode)
            materials.append(contentsOf: foundMaterials)
        }
        
        return materials
    }
    
    private func processFile(at url: URL, storageMode: MaterialStorageMode = .copy) async -> StudyMaterial? {
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            let createdAt = attributes[.creationDate] as? Date ?? Date()
            let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
            
            let materialType = MaterialType.from(extension: url.pathExtension)
            let category = categorizeMaterial(url: url)
            
            var content = ""
            if materialType == .pdf {
                content = extractPDFText(from: url) ?? ""
            }
            
            // 根据存储模式处理文件
            let storedURL: URL
            var finalStorageMode = storageMode
            switch storageMode {
            case .copy:
                if let copied = copyFileToStorage(from: url) {
                    storedURL = copied
                } else {
                    // 复制失败时降级为关联模式以保证数据不丢失
                    storedURL = url
                    finalStorageMode = .reference
                }
            case .reference:
                storedURL = url
            }
            
            let material = StudyMaterial(
                name: url.deletingPathExtension().lastPathComponent,
                type: materialType,
                category: category,
                localURL: storedURL,
                originalURL: url,
                content: content,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                fileSize: fileSize,
                storageMode: finalStorageMode
            )
            
            return material
        } catch {
            print("Error processing file: \(error)")
            return nil
        }
    }
    
    /// 获取SmartNote专用存储目录
    static func getStorageDirectory() -> URL {
        let fileManager = FileManager.default
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths.first!.appendingPathComponent("SmartNote")
        let storage = appSupport.appendingPathComponent("Materials", isDirectory: true)
        
        if !fileManager.fileExists(atPath: storage.path) {
            try? fileManager.createDirectory(at: storage, withIntermediateDirectories: true)
        }
        return storage
    }
    
    /// 复制文件到SmartNote存储目录
    private func copyFileToStorage(from sourceURL: URL) -> URL? {
        let fileManager = FileManager.default
        let storageDir = FileScannerService.getStorageDirectory()
        
        // 生成唯一文件名以避免冲突
        let originalName = sourceURL.lastPathComponent
        var destination = storageDir.appendingPathComponent(originalName)
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            let nameWithoutExt = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let newName = ext.isEmpty ? "\(nameWithoutExt)_\(counter)" : "\(nameWithoutExt)_\(counter).\(ext)"
            destination = storageDir.appendingPathComponent(newName)
            counter += 1
        }
        
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            return destination
        } catch {
            print("Error copying file: \(error)")
            return nil
        }
    }
    
    private func categorizeMaterial(url: URL) -> MaterialCategory {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        
        if name.contains("课件") || name.contains("lecture") || name.contains("ppt") {
            return .lecture
        } else if name.contains("考试") || name.contains("真题") || name.contains("exam") || name.contains("test") {
            return .exam
        } else if name.contains("笔记") || name.contains("note") {
            return .notes
        }
        
        return .other
    }
    
    private func extractPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else {
            return nil
        }
        
        var text = ""
        for i in 0..<min(document.pageCount, 5) {
            if let page = document.page(at: i),
               let pageText = page.string {
                text += pageText + "\n"
            }
        }
        
        return text.isEmpty ? nil : text
    }
    
    func getQuickScanDirectories() -> [URL] {
        let fileManager = FileManager.default
        return [
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
        ].compactMap { $0 }
    }
}
