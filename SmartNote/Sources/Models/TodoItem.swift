import Foundation

struct TodoItem: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var description: String
    var category: String
    var priority: TodoPriority
    var status: TodoStatus
    var createdAt: Date
    var updatedAt: Date
    var dueDate: Date?
    var reminderTime: Date?
    var completedAt: Date?
    var isPinned: Bool
    var tags: [String]
    
    // 番茄钟关联
    var linkedTodoID: UUID?
    var pomodoroSessions: [TodoPomodoroSession]
    
    // 时间统计
    var totalFocusedSeconds: TimeInterval
    var totalElapsedSeconds: TimeInterval
    var timeRecords: [TodoTimeRecord]
    
    init(
        id: UUID = UUID(),
        title: String = "",
        description: String = "",
        category: String = "默认",
        priority: TodoPriority = .medium,
        status: TodoStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        dueDate: Date? = nil,
        reminderTime: Date? = nil,
        completedAt: Date? = nil,
        isPinned: Bool = false,
        tags: [String] = [],
        linkedTodoID: UUID? = nil,
        pomodoroSessions: [TodoPomodoroSession] = [],
        totalFocusedSeconds: TimeInterval = 0,
        totalElapsedSeconds: TimeInterval = 0,
        timeRecords: [TodoTimeRecord] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.priority = priority
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dueDate = dueDate
        self.reminderTime = reminderTime
        self.completedAt = completedAt
        self.isPinned = isPinned
        self.tags = tags
        self.linkedTodoID = linkedTodoID
        self.pomodoroSessions = pomodoroSessions
        self.totalFocusedSeconds = totalFocusedSeconds
        self.totalElapsedSeconds = totalElapsedSeconds
        self.timeRecords = timeRecords
    }
    
    /// 完成所用总时长（创建到完成）
    var totalCompletionSeconds: TimeInterval {
        if let completedAt = completedAt {
            return completedAt.timeIntervalSince(createdAt)
        }
        return Date().timeIntervalSince(createdAt)
    }
    
    /// 距离截止日期的剩余时间
    func timeUntilDue() -> TimeInterval? {
        guard let dueDate = dueDate else { return nil }
        return dueDate.timeIntervalSinceNow
    }
    
    /// 是否已逾期
    var isOverdue: Bool {
        guard let dueDate = dueDate else { return false }
        return status != .completed && dueDate < Date()
    }
    
    /// 距截止日期的人类可读描述
    func dueDateText() -> String {
        guard let dueDate = dueDate else { return "无截止" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        let calendar = Calendar.current
        
        if calendar.isDateInToday(dueDate) {
            formatter.dateFormat = "HH:mm"
            return "今天 \(formatter.string(from: dueDate))"
        } else if calendar.isDateInTomorrow(dueDate) {
            formatter.dateFormat = "HH:mm"
            return "明天 \(formatter.string(from: dueDate))"
        } else if calendar.isDate(dueDate, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.dateFormat = "EEEE HH:mm"
            return formatter.string(from: dueDate)
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: dueDate)
        }
    }
}

enum TodoPriority: String, Codable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case urgent
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .urgent: return "紧急"
        }
    }
    
    var color: String {
        switch self {
        case .low: return "gray"
        case .medium: return "blue"
        case .high: return "orange"
        case .urgent: return "red"
        }
    }
    
    var sortValue: Int {
        switch self {
        case .urgent: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }
}

enum TodoStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case inProgress
    case completed
    case archived
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .pending: return "待办"
        case .inProgress: return "进行中"
        case .completed: return "已完成"
        case .archived: return "已归档"
        }
    }
    
    var iconName: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        case .archived: return "archivebox"
        }
    }
}

/// 番茄钟会话记录
struct TodoPomodoroSession: Codable, Identifiable, Hashable {
    let id: UUID
    var startTime: Date
    var endTime: Date?
    var duration: TimeInterval
    var completed: Bool
    
    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        duration: TimeInterval = 0,
        completed: Bool = false
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.completed = completed
    }
}

/// 累计处理时间记录
struct TodoTimeRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var startTime: Date
    var endTime: Date?
    var duration: TimeInterval
    var note: String
    
    init(
        id: UUID = UUID(),
        startTime: Date = Date(),
        endTime: Date? = nil,
        duration: TimeInterval = 0,
        note: String = ""
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.note = note
    }
}

struct TodoCategory: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var color: String
    var icon: String
    
    init(id: UUID = UUID(), name: String, color: String = "blue", icon: String = "folder") {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
    }
}

/// 统计时间维度
enum TodoStatisticsPeriod: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        }
    }
}

/// 单个时间段的统计数据
struct TodoStatisticsData: Identifiable, Hashable {
    let id = UUID()
    let periodStart: Date
    let periodLabel: String
    let completedCount: Int
    let totalCount: Int
    let focusedSeconds: TimeInterval
    let elapsedSeconds: TimeInterval
    
    var completionRate: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }
}
