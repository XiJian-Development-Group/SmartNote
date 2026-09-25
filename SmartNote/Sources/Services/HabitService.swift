import Foundation
import UserNotifications

/// 管理用户习惯与打卡，并负责安排提醒。
///
/// 初始化只加载数据，不请求通知权限。权限请求只发生在 add/update 这类用户
/// 主动开启/编辑提醒的路径；打卡、启动恢复和后台安排只查询当前状态。
class HabitService: ObservableObject {
    static let shared = HabitService()

    @Published private(set) var habits: [Habit] = []
    @Published private(set) var lastNotificationResult: NotificationOperationResult?
    @Published private(set) var lastNotificationError: String?

    private let storage: StorageService
    private let notification: NotificationService

    init(
        storage: StorageService = StorageService(),
        notification: NotificationService = NotificationService.shared
    ) {
        self.storage = storage
        self.notification = notification
        load()
        // 启动时可以恢复已有授权的提醒，但只查询状态并安排已有请求，绝不调用
        // requestAuthorization；真正的权限请求仍只发生在用户主动开启/编辑路径。
        Task { [weak self] in
            guard let self else { return }
            _ = await self.scheduleNextNotificationsForAll(requestPermissionIfNeeded: false)
        }
    }

    // MARK: - CRUD

    @discardableResult
    func addHabit(_ habit: Habit) -> Task<NotificationOperationResult, Never> {
        guard habit.isEnabled else {
            habits.append(habit)
            save()
            return Task {
                .skipped(reason: "习惯提醒未启用。")
            }
        }

        // 先以“未启用”落盘，只有通知请求真实成功后才把用户选择保存为启用。
        // 这样权限拒绝/系统 add 失败不会留下一个看似已启用的提醒。
        var pendingHabit = habit
        pendingHabit.isEnabled = false
        habits.append(pendingHabit)
        save()

        return Task { [weak self] in
            guard let self else {
                return .failure(NotificationFailure(
                    reason: .addFailed,
                    message: "习惯服务已释放，提醒未安排。"
                ))
            }
            // addHabit 是用户主动添加并开启习惯的路径；已有权限时 requestAuthorization
            // 只查询状态，不会重复弹框。
            let result = await self.scheduleNextNotification(
                for: habit,
                requestPermissionIfNeeded: true
            )
            await self.applyEnablementResult(result, habitID: habit.id, requestedHabit: habit)
            return result
        }
    }

    @discardableResult
    func updateHabit(_ habit: Habit) -> Task<NotificationOperationResult, Never> {
        guard let idx = habits.firstIndex(where: { $0.id == habit.id }) else {
            return Task { .skipped(reason: "找不到要更新的习惯。") }
        }
        if !habit.isEnabled {
            habits[idx] = habit
            save()
            notification.removePendingNotification(identifier: NotificationIdentifiers.habit(habit.id))
            return Task { .skipped(reason: "习惯提醒已关闭。") }
        }

        // 与 addHabit 相同：先不让失败的请求以 enabled 状态写入磁盘。
        var pendingHabit = habit
        pendingHabit.isEnabled = false
        habits[idx] = pendingHabit
        save()

        return Task { [weak self] in
            guard let self else {
                return .failure(NotificationFailure(
                    reason: .addFailed,
                    message: "习惯服务已释放，提醒未安排。"
                ))
            }
            // 用户主动编辑并保持开启时，允许在这个上下文中请求一次权限。
            let result = await self.scheduleNextNotification(
                for: habit,
                requestPermissionIfNeeded: true
            )
            await self.applyEnablementResult(result, habitID: habit.id, requestedHabit: habit)
            return result
        }
    }

    private func applyEnablementResult(
        _ result: NotificationOperationResult,
        habitID: UUID,
        requestedHabit: Habit
    ) async {
        let enabled: Bool
        if case .success = result {
            enabled = true
        } else {
            enabled = false
        }

        await MainActor.run {
            if let index = self.habits.firstIndex(where: { $0.id == habitID }) {
                var persistedHabit = requestedHabit
                persistedHabit.isEnabled = enabled
                self.habits[index] = persistedHabit
            }
        }
        save()
        await saveNotificationResult(result)
    }

    func deleteHabit(id: UUID) {
        habits.removeAll { $0.id == id }
        save()
        notification.removePendingNotification(identifier: NotificationIdentifiers.habit(id))
    }

    /// 在指定时间打卡，返回是否成功。打卡不会触发权限请求。
    @discardableResult
    func checkIn(habitId: UUID, at date: Date = Date()) -> Bool {
        guard let idx = habits.firstIndex(where: { $0.id == habitId }) else { return false }
        habits[idx].checkIns.append(date)
        save()
        let scheduledHabit = habits[idx]
        Task { [weak self] in
            guard let self else { return }
            let result = await self.scheduleNextNotification(
                for: scheduledHabit,
                requestPermissionIfNeeded: false
            )
            await self.saveNotificationResult(result)
        }
        return true
    }

    private func authorizationFailure(for status: NotificationAuthorizationStatus) -> NotificationFailure {
        switch status {
        case .notDetermined:
            return NotificationFailure(reason: .authorizationRequired)
        case .denied:
            return NotificationFailure(reason: .authorizationDenied)
        case .restricted, .unknown:
            return NotificationFailure(reason: .systemRestricted)
        case .authorized, .provisional, .ephemeral:
            return NotificationFailure(reason: .systemRestricted)
        }
    }

    private func saveNotificationResult(_ result: NotificationOperationResult) async {
        let errorMessage: String?
        switch result {
        case .success:
            errorMessage = nil
        case .skipped(let reason):
            errorMessage = reason
        case .failure(let failure):
            errorMessage = failure.message
        }
        await MainActor.run {
            self.lastNotificationResult = result
            self.lastNotificationError = errorMessage
        }
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
        let components = calendar.dateComponents([.hour, .minute], from: habit.reminderTime ?? Date())

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

    /// 安排习惯的下一次提醒，并返回真实 add 结果。
    ///
    /// `requestPermissionIfNeeded` 只有用户主动开启/编辑路径才应为 true；默认
    /// false 可安全用于启动恢复、打卡和后台检查。
    @discardableResult
    func scheduleNextNotification(
        for habit: Habit,
        requestPermissionIfNeeded: Bool = false
    ) async -> NotificationOperationResult {
        let identifier = NotificationIdentifiers.habit(habit.id)
        // 同一习惯只保留一个 pending 请求，重复开关/多设备恢复不会堆叠。
        notification.removePendingNotification(identifier: identifier)

        guard habit.isEnabled else {
            let result = NotificationOperationResult.skipped(reason: "习惯提醒已关闭。")
            await saveNotificationResult(result)
            return result
        }
        guard let next = computeNextOccurrence(for: habit, after: Date()) else {
            let result = NotificationOperationResult.skipped(reason: "该习惯没有下一次提醒时间。")
            await saveNotificationResult(result)
            return result
        }

        let authorization: NotificationAuthorizationResult
        if requestPermissionIfNeeded {
            authorization = await notification.requestAuthorization()
        } else {
            let status = await notification.checkAuthorization()
            authorization = status.canSendNotifications
                ? .success(status)
                : .failure(authorizationFailure(for: status))
        }

        guard case .success(let status) = authorization else {
            let result: NotificationOperationResult
            if case .failure(let failure) = authorization {
                result = .failure(failure)
            } else {
                result = .failure(NotificationFailure(reason: .authorizationRequired))
            }
            await saveNotificationResult(result)
            return result
        }

        // 习惯名称属于用户内容，正文只使用中性描述；详情只保留 habitID，
        // 供 App 将来在用户点击通知后自行查询。
        let content = NotificationService.makePrivateContent(
            title: "习惯打卡提醒",
            body: "习惯打卡提醒",
            userInfo: [
                "kind": "habit",
                "habitID": habit.id.uuidString
            ]
        )
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let result = await notification.submitNotification(
            identifier: identifier,
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: status
        )
        await saveNotificationResult(result)
        return result
    }

    /// 后台/启动恢复入口：只查询权限和安排已有授权的请求，不主动弹框。
    @discardableResult
    func scheduleNextNotificationsForAll(requestPermissionIfNeeded: Bool = false) async -> [NotificationOperationResult] {
        var results: [NotificationOperationResult] = []
        for habit in habits where habit.isEnabled {
            results.append(await scheduleNextNotification(
                for: habit,
                requestPermissionIfNeeded: requestPermissionIfNeeded
            ))
        }
        return results
    }
}
