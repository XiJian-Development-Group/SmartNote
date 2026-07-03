import Foundation
import UserNotifications

/// 管理用户习惯与打卡，并负责安排提醒
class HabitService: ObservableObject {
    static let shared = HabitService()

    @Published private(set) var habits: [Habit] = []

    private let storage = StorageService()
    private let notification = NotificationService.shared

    private init() {
        load()
        // 每次启动时为所有启用的习惯安排下一次提醒
        Task {
            await scheduleNextNotificationsForAll()
        }
    }

    // MARK: - CRUD
    func addHabit(_ habit: Habit) {
        habits.append(habit)
        save()
        Task { await scheduleNextNotification(for: habit) }
    }

    func updateHabit(_ habit: Habit) {
        if let idx = habits.firstIndex(where: { $0.id == habit.id }) {
            habits[idx] = habit
            save()
            Task { await scheduleNextNotification(for: habit) }
        }
    }

    func deleteHabit(id: UUID) {
        habits.removeAll { $0.id == id }
        save()
        // 取消对应 pending notification
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["habit_\(id.uuidString)"])
    }

    /// 在指定时间打卡，返回是否成功
    @discardableResult
    func checkIn(habitId: UUID, at date: Date = Date()) -> Bool {
        guard let idx = habits.firstIndex(where: { $0.id == habitId }) else { return false }
        habits[idx].checkIns.append(date)
        save()
        Task { await scheduleNextNotification(for: habits[idx]) }
        return true
    }

    // MARK: - 统计功能
    enum DayStatus: Codable {
        case checked
        case missed
        case none // 没有安排打卡
    }

    private func startOfDay(_ d: Date) -> Date {
        Calendar.current.startOfDay(for: d)
    }

    /// 判断某一天是否为习惯安排日（只看日期，不看时间）
    private func isScheduled(on date: Date, for habit: Habit) -> Bool {
        let cal = Calendar.current
        let day = startOfDay(date)
        let start = startOfDay(habit.startDate)
        if day < start { return false }
        if let end = habit.endDate, day > startOfDay(end) { return false }

        let interval = max(1, habit.intervalCount)
        switch habit.intervalType {
        case .daily, .everyNDays:
            let diff = cal.dateComponents([.day], from: start, to: day).day ?? 0
            return diff % interval == 0
        case .weekly:
            // 同一星期几，且相隔周数满足间隔
            let baseWeekday = cal.component(.weekday, from: start)
            let weekday = cal.component(.weekday, from: day)
            guard weekday == baseWeekday else { return false }
            let diffDays = cal.dateComponents([.day], from: start, to: day).day ?? 0
            let weeks = diffDays / 7
            return weeks % interval == 0
        case .monthly:
            let baseDay = cal.component(.day, from: start)
            let dayOfMonth = cal.component(.day, from: day)
            guard dayOfMonth == baseDay else { return false }
            let months = cal.dateComponents([.month], from: start, to: day).month ?? 0
            return months % interval == 0
        }
    }

    /// 返回最近 N 天（包含今天）的每日状态（从最旧到最新）
    func history(for habit: Habit, days: Int) -> [(date: Date, status: DayStatus)] {
        guard days > 0 else { return [] }
        var res: [(Date, DayStatus)] = []
        let cal = Calendar.current
        let todayStart = startOfDay(Date())
        let checkedSet: Set<Date> = Set(habit.checkIns.map { startOfDay($0) })

        for i in stride(from: days - 1, through: 0, by: -1) {
            if let d = cal.date(byAdding: .day, value: -i, to: todayStart) {
                if isScheduled(on: d, for: habit) {
                    let status: DayStatus = checkedSet.contains(startOfDay(d)) ? .checked : .missed
                    res.append((d, status))
                } else {
                    res.append((d, .none))
                }
            }
        }
        return res
    }

    func totalCheckIns(for habit: Habit) -> Int {
        habit.checkIns.count
    }

    func missedCount(for habit: Habit, inLast days: Int) -> Int {
        history(for: habit, days: days).filter { $0.status == .missed }.count
    }

    /// 当前连续打卡天数（基于已安排的发生日，从最近一次安排日向过去计数，遇到第一处未打卡即停止）
    func currentStreak(for habit: Habit, lookbackDays: Int = 365) -> Int {
        let hist = history(for: habit, days: lookbackDays).reversed() // newest first
        // 只考虑安排日
        let occ = hist.filter { $0.status != .none }
        var streak = 0
        for (_, status) in occ {
            if status == .checked { streak += 1 } else { break }
        }
        return streak
    }

    // MARK: - Persistence
    private func save() {
        storage.saveHabits(habits)
    }

    private func load() {
        habits = storage.loadHabits()
    }

    // MARK: - 通知安排
    private func computeNextOccurrence(for habit: Habit, after fromDate: Date = Date()) -> Date? {
        guard habit.isEnabled else { return nil }

        let calendar = Calendar.current
        let start = habit.startDate
        let end = habit.endDate

        // 基础时间：若有最近打卡，基于打卡时间；否则以 start 为基准
        let base = (habit.checkIns.sorted(by: { $0 > $1 }).first) ?? start

        // 目标时分
        var components = calendar.dateComponents([.hour, .minute], from: habit.reminderTime ?? Date())

        var candidate: Date?
        switch habit.intervalType {
        case .daily:
            // 下一天的同一时间（或同一日但晚于now）
            candidate = calendar.nextDate(after: fromDate, matching: components, matchingPolicy: .nextTime)
        case .everyNDays:
            let n = max(1, habit.intervalCount)
            var d = calendar.startOfDay(for: base)
            // 递增 n 天直到在 fromDate 之后
            while d <= fromDate {
                d = calendar.date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(TimeInterval(n * 24 * 3600))
            }
            candidate = calendar.date(bySettingHour: components.hour ?? 9, minute: components.minute ?? 0, second: 0, of: d)
        case .weekly:
            let n = max(1, habit.intervalCount)
            // 使用 base 的 weekday
            let weekday = calendar.component(.weekday, from: base)
            // build components with hour/minute first to avoid initializer ambiguity
            var next = calendar.nextDate(after: fromDate, matching: DateComponents(hour: components.hour, minute: components.minute, weekday: weekday), matchingPolicy: .nextTime)
            // 如果需要间隔多周，则确保隔开 n-1 周
            // 如果初始候选在 fromDate 之前或等于 fromDate，按间隔推进直到在 fromDate 之后
            while let current = next, current <= fromDate {
                next = calendar.date(byAdding: .weekOfYear, value: n, to: current)
            }
            candidate = next
        case .monthly:
            let n = max(1, habit.intervalCount)
            let day = calendar.component(.day, from: base)
            var next = calendar.nextDate(after: fromDate, matching: DateComponents(day: day, hour: components.hour, minute: components.minute), matchingPolicy: .nextTimePreservingSmallerComponents)
            if let first = next {
                while first <= fromDate {
                    next = calendar.date(byAdding: .month, value: n, to: next ?? first)
                    if next == nil { break }
                }
            }
            candidate = next
        }

        if let c = candidate {
            if let end = end, c > end { return nil }
            return c
        }
        return nil
    }

    /// 公开查询下一个发生时间（UI 使用）
    func nextOccurrence(for habit: Habit) -> Date? {
        return computeNextOccurrence(for: habit, after: Date())
    }

    func scheduleNextNotification(for habit: Habit) async {
        guard habit.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        // 先移除旧的同 id 请求
        center.removePendingNotificationRequests(withIdentifiers: ["habit_\(habit.id.uuidString)"])

        guard let next = computeNextOccurrence(for: habit, after: Date()) else { return }

        let granted = await notification.requestAuthorization()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "打卡提醒：\(habit.title)"
        content.body = "别忘了完成你的习惯打卡：\(habit.title)。"
        content.sound = .default

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let req = UNNotificationRequest(identifier: "habit_\(habit.id.uuidString)", content: content, trigger: trigger)
        do {
            try await center.add(req)
        } catch {
            print("Failed to schedule habit notification: \(error)")
        }
    }

    func scheduleNextNotificationsForAll() async {
        for habit in habits where habit.isEnabled {
            await scheduleNextNotification(for: habit)
        }
    }
}
