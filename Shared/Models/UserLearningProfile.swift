import Foundation

struct UserLearningProfile: Codable, Identifiable {
    var id: UUID
    var isEnabled: Bool
    var analysisFrequency: AnalysisFrequency
    var lastAnalysisDate: Date?
    var nextAnalysisDate: Date?
    
    var preferences: LearningPreferences
    var characteristics: LearningCharacteristics
    
    init(
        id: UUID = UUID(),
        isEnabled: Bool = false,
        analysisFrequency: AnalysisFrequency = .weekly,
        lastAnalysisDate: Date? = nil,
        nextAnalysisDate: Date? = nil,
        preferences: LearningPreferences = LearningPreferences(),
        characteristics: LearningCharacteristics = LearningCharacteristics()
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.analysisFrequency = analysisFrequency
        self.lastAnalysisDate = lastAnalysisDate
        self.nextAnalysisDate = nextAnalysisDate
        self.preferences = preferences
        self.characteristics = characteristics
    }
    
    mutating func updateNextAnalysisDate() {
        nextAnalysisDate = analysisFrequency.nextDate(from: Date())
    }
}

enum AnalysisFrequency: String, Codable, CaseIterable {
    case never = "不刷新"
    case every2Hours = "每2小时"
    case daily = "每天"
    case weekly = "每周"
    case monthly = "每月"
    
    var description: String {
        return rawValue
    }
    
    func nextDate(from date: Date) -> Date? {
        let calendar = Calendar.current
        switch self {
        case .never:
            return nil
        case .every2Hours:
            return calendar.date(byAdding: .hour, value: 2, to: date)
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        }
    }
}

struct LearningPreferences: Codable, Hashable {
    var preferredExplanationStyle: ExplanationStyle
    var preferredDifficulty: DifficultyLevel
    var preferredExampleTypes: [ExampleType]
    var preferredLanguageTone: LanguageTone
    var preferredReviewMethod: ReviewMethod
    var attentionPoints: [String]
    var weakSubjects: [String]
    var strongSubjects: [String]
    
    init(
        preferredExplanationStyle: ExplanationStyle = .detailed,
        preferredDifficulty: DifficultyLevel = .medium,
        preferredExampleTypes: [ExampleType] = [.analogy, .practice],
        preferredLanguageTone: LanguageTone = .friendly,
        preferredReviewMethod: ReviewMethod = .spaced,
        attentionPoints: [String] = [],
        weakSubjects: [String] = [],
        strongSubjects: [String] = []
    ) {
        self.preferredExplanationStyle = preferredExplanationStyle
        self.preferredDifficulty = preferredDifficulty
        self.preferredExampleTypes = preferredExampleTypes
        self.preferredLanguageTone = preferredLanguageTone
        self.preferredReviewMethod = preferredReviewMethod
        self.attentionPoints = attentionPoints
        self.weakSubjects = weakSubjects
        self.strongSubjects = strongSubjects
    }
}

enum ExplanationStyle: String, Codable, CaseIterable {
    case concise = "简洁"
    case detailed = "详细"
    case example = "举例说明"
    case stepByStep = "循序渐进"
    
    var description: String {
        return rawValue
    }
}

enum DifficultyLevel: String, Codable, CaseIterable {
    case easy = "简单"
    case medium = "中等"
    case hard = "困难"
    
    var description: String {
        return rawValue
    }
}

enum ExampleType: String, Codable, CaseIterable {
    case analogy = "类比"
    case practice = "练习"
    case story = "故事"
    case diagram = "图表"
    case realLife = "实际应用"
    
    var description: String {
        return rawValue
    }
}

enum LanguageTone: String, Codable, CaseIterable {
    case professional = "专业"
    case friendly = "亲切"
    case casual = "轻松"
    case academic = "学术"
    
    var description: String {
        return rawValue
    }
}

enum ReviewMethod: String, Codable, CaseIterable {
    case spaced = "间隔重复"
    case active = "主动回忆"
    case passive = "被动复习"
    case mixed = "混合"
    
    var description: String {
        return rawValue
    }
}

struct LearningCharacteristics: Codable, Hashable {
    var averageSessionDuration: TimeInterval
    var preferredStudyTime: StudyTime
    var learningPace: LearningPace
    var memoryType: MemoryType
    var noteTakingStyle: NoteTakingStyle
    var questionFrequency: QuestionFrequency
    var errorPatterns: [String]
    var recentTopics: [String]
    
    init(
        averageSessionDuration: TimeInterval = 0,
        preferredStudyTime: StudyTime = .evening,
        learningPace: LearningPace = .moderate,
        memoryType: MemoryType = .visual,
        noteTakingStyle: NoteTakingStyle = .summary,
        questionFrequency: QuestionFrequency = .medium,
        errorPatterns: [String] = [],
        recentTopics: [String] = []
    ) {
        self.averageSessionDuration = averageSessionDuration
        self.preferredStudyTime = preferredStudyTime
        self.learningPace = learningPace
        self.memoryType = memoryType
        self.noteTakingStyle = noteTakingStyle
        self.questionFrequency = questionFrequency
        self.errorPatterns = errorPatterns
        self.recentTopics = recentTopics
    }
}

enum StudyTime: String, Codable, CaseIterable {
    case morning = "早上"
    case afternoon = "下午"
    case evening = "晚上"
    case night = "深夜"
    
    var description: String {
        return rawValue
    }
}

enum LearningPace: String, Codable, CaseIterable {
    case slow = "慢速"
    case moderate = "适中"
    case fast = "快速"
    
    var description: String {
        return rawValue
    }
}

enum MemoryType: String, Codable, CaseIterable {
    case visual = "视觉型"
    case auditory = "听觉型"
    case kinesthetic = "动觉型"
    case mixed = "混合型"
    
    var description: String {
        return rawValue
    }
}

enum NoteTakingStyle: String, Codable, CaseIterable {
    case outline = "大纲式"
    case summary = "总结式"
    case detailed = "详细式"
    case diagram = "图表式"
    case cornell = "康奈尔式"
    
    var description: String {
        return rawValue
    }
}

enum QuestionFrequency: String, Codable, CaseIterable {
    case low = "偶尔"
    case medium = "一般"
    case high = "频繁"
    
    var description: String {
        return rawValue
    }
}
