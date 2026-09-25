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
    
    /// 统一的中英日韩混合字数：CJK 字符逐字计数，其余内容按空白分成
    /// 英文/数字词；标点、空白和 emoji 等既不是 CJK 字符、也不含字母或数字的
    /// token 不计数。旧调用方使用的 `chineseWordCount` 与此保持同一口径。
    var wordCount: Int {
        Self.countWords(in: content)
    }
    
    /// 兼容旧名称；不要把 CJK 字符再加入英文/数字词中，避免重复计数。
    var chineseWordCount: Int {
        wordCount
    }
    
    /// 统计一段文本的字数，供模型和编辑器共用同一实现。
    static func countWords(in text: String) -> Int {
        var cjkCount = 0
        var nonCJKText = ""
        
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                cjkCount += 1
            } else {
                nonCJKText.unicodeScalars.append(scalar)
            }
        }
        
        // 先移除 CJK，再按空白分词；一个 token 只有含有字母或数字时才是一个词。
        // 因此标点不会计数，也不会与相邻的 CJK 字符重复计数。
        let nonCJKWords = nonCJKText
            .split(whereSeparator: { $0.isWhitespace })
            .reduce(into: 0) { count, token in
                if token.contains(where: { $0.isLetter || $0.isNumber }) {
                    count += 1
                }
            }
        
        return cjkCount + nonCJKWords
    }
    
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // 覆盖常用汉字、扩展汉字、假名、谚文和 CJK 扩展区；标点所在区间
        // （例如 U+3000...U+303F、U+30FB）不在这些范围内。
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
            || (0x3040...0x309F).contains(value)
            || (0x30A1...0x30FA).contains(value)
            || (0x30FC...0x30FF).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
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
