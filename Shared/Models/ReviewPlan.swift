import Foundation

struct ReviewPlan: Identifiable, Codable, Hashable {
    let id: UUID
    var subject: String
    var examDate: Date
    var topics: [ReviewTopic]
    var dailyPlans: [DailyPlan]
    var createdAt: Date
    var isActive: Bool
    
    init(
        id: UUID = UUID(),
        subject: String,
        examDate: Date,
        topics: [ReviewTopic] = [],
        dailyPlans: [DailyPlan] = [],
        createdAt: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.subject = subject
        self.examDate = examDate
        self.topics = topics
        self.dailyPlans = dailyPlans
        self.createdAt = createdAt
        self.isActive = isActive
    }
    
    var totalDays: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: examDate).day ?? 0
    }
    
    var completedTasks: Int {
        dailyPlans.flatMap { $0.tasks }.filter { $0.isCompleted }.count
    }
    
    var totalTasks: Int {
        dailyPlans.flatMap { $0.tasks }.count
    }
    
    var progress: Double {
        guard totalTasks > 0 else { return 0 }
        return Double(completedTasks) / Double(totalTasks)
    }
    
    var daysUntilExam: String {
        let days = totalDays
        if days < 0 {
            return "已过期"
        } else if days == 0 {
            return "今天考试"
        } else if days == 1 {
            return "明天考试"
        } else {
            return "\(days) 天后考试"
        }
    }
}

struct ReviewTopic: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var importance: TopicImportance
    var isMastered: Bool
    var relatedMaterialIds: [UUID]
    
    init(
        id: UUID = UUID(),
        name: String,
        importance: TopicImportance = .medium,
        isMastered: Bool = false,
        relatedMaterialIds: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.importance = importance
        self.isMastered = isMastered
        self.relatedMaterialIds = relatedMaterialIds
    }
}

enum TopicImportance: String, Codable, CaseIterable {
    case high = "高"
    case medium = "中"
    case low = "低"
    
    var color: String {
        switch self {
        case .high: return "red"
        case .medium: return "orange"
        case .low: return "green"
        }
    }
    
    var priority: Int {
        switch self {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }
}

struct DailyPlan: Identifiable, Codable, Hashable {
    let id: UUID
    var date: Date
    var tasks: [ReviewTask]
    
    init(
        id: UUID = UUID(),
        date: Date,
        tasks: [ReviewTask] = []
    ) {
        self.id = id
        self.date = date
        self.tasks = tasks
    }
    
    var isCompleted: Bool {
        tasks.allSatisfy { $0.isCompleted }
    }
    
    var completedCount: Int {
        tasks.filter { $0.isCompleted }.count
    }
}

struct ReviewTask: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var description: String
    var topicId: UUID?
    var materialIds: [UUID]
    var estimatedMinutes: Int
    var isCompleted: Bool
    var completedAt: Date?
    
    init(
        id: UUID = UUID(),
        title: String,
        description: String = "",
        topicId: UUID? = nil,
        materialIds: [UUID] = [],
        estimatedMinutes: Int = 30,
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.topicId = topicId
        self.materialIds = materialIds
        self.estimatedMinutes = estimatedMinutes
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }
}
