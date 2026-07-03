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
