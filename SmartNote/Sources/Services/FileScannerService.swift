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
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
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
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
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

            // 关联文件在当前读取授权仍有效时创建安全作用域书签；复制模式无需保留外部授权。
            let bookmarkData = finalStorageMode == .reference
                ? StudyMaterial.makeSecurityScopedBookmark(for: url)
                : nil

            // 名称取自「实际落盘的那个文件」。同名文件被加上 _1/_2 后缀时，
            // 若仍用源文件名，列表里会出现多条同名资料，搜索与筛选会全部命中。
            let material = StudyMaterial(
                name: storedURL.deletingPathExtension().lastPathComponent,
                type: materialType,
                category: category,
                localURL: storedURL,
                originalURL: url,
                bookmarkData: bookmarkData,
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
    
    /// 按文件名猜测分类。
    ///
    /// 文件名是自动分类唯一的信号，因此按「关键词出现得最早」判定归属：
    /// 「历史笔记-lecture」以「笔记」开头，归笔记而不是课件；
    /// 「lecture-历史笔记」反过来归课件。同时中文复合词按子串参与比较，
    /// 「期末考试」里的「考试」能命中。
    private func categorizeMaterial(url: URL) -> MaterialCategory {
        let raw = url.deletingPathExtension().lastPathComponent.lowercased()
        // 去掉日期/序号等前缀与「[重要]」这类标记，再按分隔符切段
        let stripped = raw
            .replacingOccurrences(of: #"^[\d_\-.\s]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^[\[（(【].*?[\]）)】]\s*"#, with: "", options: .regularExpression)
        guard !stripped.isEmpty else { return .other }

        let separators: Set<Character> = ["-", "_", ".", " ", "、", "－", "—"]
        let segments = stripped.split(whereSeparator: { separators.contains($0) }).map(String.init)

        /// 返回某类别关键词的最早出现位置；无命中返回 nil。
        func earliestHit(_ tokens: [String]) -> Int? {
            var hits: [Int] = []
            var cursor = stripped.startIndex
            for segment in segments {
                // 段内位置换算成整串位置，便于跨段比较
                let searchRange = cursor..<stripped.endIndex
                if let found = stripped.range(of: segment, range: searchRange) {
                    cursor = found.upperBound
                }
                let segmentStart = stripped.distance(from: stripped.startIndex, to: cursor)
                    - segment.count
                for token in tokens {
                    if segment == token { hits.append(segmentStart) }
                    else if segment.hasPrefix(token) || segment.hasSuffix(token) {
                        hits.append(segmentStart + (segment.hasPrefix(token) ? 0 : segment.count - token.count))
                    } else if let range = segment.range(of: token) {
                        hits.append(segmentStart + segment.distance(from: segment.startIndex, to: range.lowerBound))
                    }
                }
            }
            return hits.min()
        }

        let candidates: [(MaterialCategory, Int)] = [
            (.lecture, earliestHit(["课件", "讲义", "lecture", "ppt", "slide"]) ?? Int.max),
            (.exam, earliestHit(["考试", "真题", "试卷", "exam", "test", "quiz"]) ?? Int.max),
            (.notes, earliestHit(["笔记", "note", "notes"]) ?? Int.max)
        ]
        let hit = candidates.min { $0.1 < $1.1 }
        guard let best = hit, best.1 != Int.max else { return .other }
        return best.0
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
