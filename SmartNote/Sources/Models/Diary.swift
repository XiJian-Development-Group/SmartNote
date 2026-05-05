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
    
    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        category: String = "默认",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        linkedMaterialIDs: [UUID] = [],
        isEncrypted: Bool = false
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
    }
    
    var wordCount: Int {
        content.count
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
