import Foundation

struct DiaryEntry: Codable, Identifiable {
    let id: UUID
    var title: String
    var content: String
    var category: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var linkedMaterialIDs: [UUID]
    var isEncrypted: Bool
    var imagePaths: [String]  // 图片文件路径列表（相对路径）
    var whiteboardID: UUID?   // 关联的白板文档 ID
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        category: String = "默认",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        linkedMaterialIDs: [UUID] = [],
        isEncrypted: Bool = false,
        imagePaths: [String] = [],
        whiteboardID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.category = category
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.linkedMaterialIDs = linkedMaterialIDs
        self.isEncrypted = isEncrypted
        self.imagePaths = imagePaths
        self.whiteboardID = whiteboardID
    }
    
    var wordCount: Int {
        content.count
    }
    
    var chineseWordCount: Int {
        // 中文字符数 + 英文单词数
        let stripped = content.replacingOccurrences(of: " ", with: "")
        let chineseChars = stripped.unicodeScalars.filter { 
            (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        }.count
        let englishWords = content.split{ !$0.isLetter && !$0.isNumber }.count
        return chineseChars + englishWords
    }
}

struct DiaryCategory: Codable, Identifiable {
    let id: UUID
    var name: String
    var color: String
    
    init(id: UUID = UUID(), name: String, color: String = "#007AFF") {
        self.id = id
        self.name = name
        self.color = color
    }
}

struct DiaryEncryptionSettings: Codable {
    var isEnabled: Bool
    var password: String
    var securityQuestion: String
    var securityAnswer: String
    
    init(isEnabled: Bool = false, password: String = "", securityQuestion: String = "", securityAnswer: String = "") {
        self.isEnabled = isEnabled
        self.password = password
        self.securityQuestion = securityQuestion
        self.securityAnswer = securityAnswer
    }
}
