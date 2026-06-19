import Foundation

struct StudyMaterial: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var type: MaterialType
    var category: MaterialCategory
    var localURL: URL?
    var originalURL: URL?
    var content: String
    var extractedText: String?
    var keywords: [String]?
    var createdAt: Date
    var modifiedAt: Date
    var fileSize: Int64
    var isFavorite: Bool
    var notes: String
    var storageMode: MaterialStorageMode
    
    init(
        id: UUID = UUID(),
        name: String,
        type: MaterialType,
        category: MaterialCategory = .other,
        localURL: URL? = nil,
        originalURL: URL? = nil,
        content: String = "",
        extractedText: String? = nil,
        keywords: [String]? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        fileSize: Int64 = 0,
        isFavorite: Bool = false,
        notes: String = "",
        storageMode: MaterialStorageMode = .copy
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.category = category
        self.localURL = localURL
        self.originalURL = originalURL
        self.content = content
        self.extractedText = extractedText
        self.keywords = keywords
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.isFavorite = isFavorite
        self.notes = notes
        self.storageMode = storageMode
    }
    
    var displayFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
    
    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }
}

enum MaterialType: String, Codable, CaseIterable {
    case pdf = "PDF"
    case word = "Word"
    case powerpoint = "PPT"
    case image = "图片"
    case text = "文本"
    case other = "其他"
    
    var icon: String {
        switch self {
        case .pdf: return "doc.text.fill"
        case .word: return "doc.fill"
        case .powerpoint: return "play.rectangle.fill"
        case .image: return "photo.fill"
        case .text: return "doc.plaintext.fill"
        case .other: return "doc.fill"
        }
    }
    
    static func from(extension ext: String) -> MaterialType {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "doc", "docx": return .word
        case "ppt", "pptx": return .powerpoint
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff": return .image
        case "txt", "md": return .text
        default: return .other
        }
    }
}

enum MaterialCategory: String, Codable, CaseIterable {
    case lecture = "课件"
    case exam = "真题"
    case notes = "笔记"
    case personalAnalysis = "个人分析"
    case other = "其他"
    
    var icon: String {
        switch self {
        case .lecture: return "book.fill"
        case .exam: return "pencil.and.list.clipboard"
        case .notes: return "note.text"
        case .personalAnalysis: return "person.fill.questionmark"
        case .other: return "folder.fill"
        }
    }
    
    var color: String {
        switch self {
        case .lecture: return "blue"
        case .exam: return "red"
        case .notes: return "green"
        case .personalAnalysis: return "purple"
        case .other: return "gray"
        }
    }
}

/// 资料存储模式
enum MaterialStorageMode: String, Codable, CaseIterable, Identifiable {
    case copy
    case reference
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .copy: return "复制"
        case .reference: return "关联"
        }
    }
    
    var description: String {
        switch self {
        case .copy: return "复制文件到SmartNote存储目录，原文件变动不影响资料"
        case .reference: return "仅创建文件链接，原文件变动会同步更新"
        }
    }
    
    var icon: String {
        switch self {
        case .copy: return "doc.on.doc.fill"
        case .reference: return "link"
        }
    }
}
