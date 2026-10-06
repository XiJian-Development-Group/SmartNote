import Foundation
import Foundation

struct WrongQuestion: Codable, Identifiable {
    let id: UUID
    var questionContent: String
    var correctAnswer: String
    var studentAnswer: String
    var errorReason: String
    var knowledgePoints: [String]
    var masteryLevel: MasteryLevel
    var source: String
    var subject: String
    var createdAt: Date
    var lastReviewedAt: Date?
    var nextReviewAt: Date?
    var reviewCount: Int
    
    init(
        id: UUID = UUID(),
        questionContent: String,
        correctAnswer: String,
        studentAnswer: String = "",
        errorReason: String = "",
        knowledgePoints: [String] = [],
        masteryLevel: MasteryLevel = .notReviewed,
        source: String = "",
        subject: String = "",
        createdAt: Date = Date(),
        lastReviewedAt: Date? = nil,
        nextReviewAt: Date? = nil,
        reviewCount: Int = 0
    ) {
        self.id = id
        self.questionContent = questionContent
        self.correctAnswer = correctAnswer
        self.studentAnswer = studentAnswer
        self.errorReason = errorReason
        self.knowledgePoints = knowledgePoints
        self.masteryLevel = masteryLevel
        self.source = source
        self.subject = subject
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

enum MasteryLevel: String, Codable, CaseIterable {
    case notReviewed = "未复习"
    case completelyForgotten = "完全忘记"
    case rememberWithDifficulty = "困难想起"
    case rememberWithEase = "轻松想起"
    case completelyMastered = "完全掌握"
    
    var color: String {
        switch self {
        case .notReviewed: return "gray"
        case .completelyForgotten: return "red"
        case .rememberWithDifficulty: return "orange"
        case .rememberWithEase: return "blue"
        case .completelyMastered: return "green"
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension MasteryLevel {
    /// SwiftUI 颜色。
    ///
    /// 上面那个 `color` 是颜色名，供不引入 SwiftUI 的地方使用；
    /// 这里把它映射成 `Color`，让两个平台共用同一份映射表。
    var tintColor: Color {
        switch color {
        case "red": return .red
        case "orange": return .orange
        case "blue": return .blue
        case "green": return .green
        default: return .gray
        }
    }
}
#endif

@MainActor
final class WrongQuestionService: ObservableObject {
@MainActor static let shared = WrongQuestionService()
    
    @Published var questions: [WrongQuestion] = []
    
    private let storageService = StorageService()
    
    private init() {
        loadQuestions()
    }
    
    func addQuestion(_ question: WrongQuestion) {
        questions.append(question)
        saveQuestions()
    }
    
    func updateQuestion(_ question: WrongQuestion) {
        if let index = questions.firstIndex(where: { $0.id == question.id }) {
            questions[index] = question
            saveQuestions()
        }
    }
    
    func deleteQuestion(_ question: WrongQuestion) {
        questions.removeAll { $0.id == question.id }
        saveQuestions()
    }
    
    func getQuestionsForReview() -> [WrongQuestion] {
        let now = Date()
        return questions.filter { question in
            guard let nextReview = question.nextReviewAt else { return true }
            return nextReview <= now
        }.sorted { ($0.nextReviewAt ?? Date.distantPast) < ($1.nextReviewAt ?? Date.distantPast) }
    }
    
    func getQuestionsBySubject(_ subject: String) -> [WrongQuestion] {
        return questions.filter { $0.subject == subject }
    }
    
    func getQuestionsByKnowledgePoint(_ point: String) -> [WrongQuestion] {
        return questions.filter { $0.knowledgePoints.contains(point) }
    }
    
    private func loadQuestions() {
        questions = storageService.loadWrongQuestions()
    }
    
    private func saveQuestions() {
        storageService.saveWrongQuestions(questions)
    }
}
