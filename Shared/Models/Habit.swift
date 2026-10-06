import Foundation

/// 打卡习惯模型
struct Habit: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var startDate: Date
    var endDate: Date?
    /// 间隔类型：daily = 每天 / everyNDays = 每 N 天 / weekly = 每 N 周 / monthly = 每 N 月
    var intervalType: HabitIntervalType
    var intervalCount: Int // N 值，默认 1
    /// 时间（只保留时分用于提醒）
    var reminderTime: Date?
    var isEnabled: Bool
    var checkIns: [Date]

    init(id: UUID = UUID(), title: String, startDate: Date = Date(), endDate: Date? = nil, intervalType: HabitIntervalType = .daily, intervalCount: Int = 1, reminderTime: Date? = nil, isEnabled: Bool = true, checkIns: [Date] = []) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.intervalType = intervalType
        self.intervalCount = max(1, intervalCount)
        self.reminderTime = reminderTime
        self.isEnabled = isEnabled
        self.checkIns = checkIns
    }

    /// 最近一次打卡日期（不包括时间）
    var lastCheckInDate: Date? {
        checkIns.sorted(by: { $0 > $1 }).first
    }

    /// `title` 的语义化别名，供以 `name` 描述习惯的界面使用。
    ///
    /// 纯计算属性：不参与 `Codable`，因此不影响既有 habits.json 的编码结果。
    var name: String {
        get { title }
        set { title = newValue }
    }

    /// 以“每天/每周/每月”表达的频率视图。
    ///
    /// `everyNDays`（每 N 天）在该粒度下没有对应项，按最接近的“每天”呈现，
    /// 精确间隔仍以 `intervalType`/`intervalCount` 为准。纯计算属性。
    var frequency: HabitFrequency {
        get {
            switch intervalType {
            case .daily, .everyNDays: return .daily
            case .weekly: return .weekly
            case .monthly: return .monthly
            }
        }
        set {
            intervalType = newValue.intervalType
        }
    }

    /// 当前连续打卡天数。
    ///
    /// 从最近一次打卡开始逐日回溯，遇到缺口即中断；间隔型习惯按自然日连续计算，
    /// 与「上次是否在有效期内」判定配合使用。纯计算属性。
    var currentStreak: Int {
        let calendar = Calendar.current
        let days = Set(checkIns.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: Date())
        // 今天还没打卡时，连续天数可以从昨天开始计算。
        var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        guard days.contains(cursor) else { return 0 }

        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }
}

enum HabitIntervalType: String, Codable, CaseIterable, Identifiable {
    case daily
    case everyNDays
    case weekly
    case monthly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .daily: return "每天"
        case .everyNDays: return "每 N 天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        }
    }
}

enum HabitFrequency: String, Codable, CaseIterable, Identifiable {
    case daily = "daily"
    case weekly = "weekly"
    case monthly = "monthly"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .daily: return "每天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        }
    }
    
    var intervalType: HabitIntervalType {
        switch self {
        case .daily: return .daily
        case .weekly: return .weekly
        case .monthly: return .monthly
        }
    }
}
