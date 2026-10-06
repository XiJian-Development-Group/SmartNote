import Foundation
import Foundation

struct FlashCard: Codable, Identifiable {
    let id: UUID
    var front: String
    var back: String
    var category: String
    var knowledgePoints: [String]
    var masteryLevel: MasteryLevel
    var createdAt: Date
    var lastReviewedAt: Date?
    var nextReviewAt: Date?
    var reviewCount: Int
    
    init(
        id: UUID = UUID(),
        front: String,
        back: String,
        category: String = "",
        knowledgePoints: [String] = [],
        masteryLevel: MasteryLevel = .notReviewed,
        createdAt: Date = Date(),
        lastReviewedAt: Date? = nil,
        nextReviewAt: Date? = nil,
        reviewCount: Int = 0
    ) {
        self.id = id
        self.front = front
        self.back = back
        self.category = category
        self.knowledgePoints = knowledgePoints
        self.masteryLevel = masteryLevel
        self.createdAt = createdAt
        self.lastReviewedAt = lastReviewedAt
        self.nextReviewAt = nextReviewAt
        self.reviewCount = reviewCount
    }
    
    mutating func updateMastery(_ level: MasteryLevel) {
        masteryLevel = level
        lastReviewedAt = Date()
        reviewCount += 1
        nextReviewAt = calculateNextReview(level)
    }
    
    private func calculateNextReview(_ level: MasteryLevel) -> Date? {
        let calendar = Calendar.current
        let days: Int
        
        switch level {
        case .notReviewed: days = 0
        case .completelyForgotten: days = 1
        case .rememberWithDifficulty: days = 2
        case .rememberWithEase: days = 4
        case .completelyMastered: days = 7
        }
        
        return calendar.date(byAdding: .day, value: days, to: Date())
    }
}

@MainActor
final class FlashCardService: ObservableObject {
@MainActor static let shared = FlashCardService()
    
    @Published var cards: [FlashCard] = []
    
    private let storageService = StorageService()
    
    private init() {
        loadCards()
    }
    
    func addCard(_ card: FlashCard) {
        cards.append(card)
        saveCards()
    }
    
    func updateCard(_ card: FlashCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
            saveCards()
        }
    }
    
    func deleteCard(_ card: FlashCard) {
        cards.removeAll { $0.id == card.id }
        saveCards()
    }
    
    func getCardsForReview() -> [FlashCard] {
        let now = Date()
        return cards.filter { card in
            guard let nextReview = card.nextReviewAt else { return true }
            return nextReview <= now
        }.sorted { ($0.nextReviewAt ?? Date.distantPast) < ($1.nextReviewAt ?? Date.distantPast) }
    }
    
    func getCardsByCategory(_ category: String) -> [FlashCard] {
        return cards.filter { $0.category == category }
    }
    
    func generateCardsFromContent(_ content: String, category: String) async -> [FlashCard] {
        var generatedCards: [FlashCard] = []
        
        let prompt = """
        请从以下学习资料中提取可以用于背诵的知识点，生成闪卡（卡片对）。
        每张卡片包含正面（问题/名词）和背面（答案/解释）。
        
        要求：
        1. 提取关键名词、概念、简答题
        2. 每张卡片正面简洁明了
        3. 背面包含准确的定义或答案
        4. 返回JSON数组格式
        
        格式：
        [
            {"front": "正面内容", "back": "背面内容"},
            ...
        ]
        
        学习资料：
        \(content)
        
        请只返回JSON数组，不要其他内容。
        """
        
        return generatedCards
    }
    
    private func loadCards() {
        cards = storageService.loadFlashCards()
    }
    
    private func saveCards() {
        storageService.saveFlashCards(cards)
    }
}
