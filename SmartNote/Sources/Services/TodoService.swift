import Foundation
import SwiftUI
import Combine

/// 待办提醒安排失败时返回给调用方的明确原因。
enum TodoReminderSchedulingError: LocalizedError {
    case invalidReminderTime
    case notificationsNotAuthorized
    case schedulingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidReminderTime:
            return "提醒时间必须晚于当前时间"
        case .notificationsNotAuthorized:
            return "未获得通知权限，无法启用待办提醒"
        case .schedulingFailed(let message):
            return "安排待办提醒失败：\(message)"
        }
    }
}

/// 待办服务：单例，负责待办项的增删改查、持久化、搜索筛选、分类管理
@MainActor
class TodoService: ObservableObject {
    static let shared = TodoService()
    
    @Published var items: [TodoItem] = []
    @Published var categories: [TodoCategory] = []
    /// 最近一次提醒安排结果，供调用方展示失败原因；服务不会把失败当作成功。
    @Published private(set) var lastReminderSchedulingResult: Result<Void, TodoReminderSchedulingError>?
    
    private let storageService = StorageService()
    private let pomodoroService = PomodoroTimer.shared
    
    private init() {
        loadAll()
    }
    
    // MARK: - 数据加载
    
    func loadAll() {
        items = storageService.loadTodoItems()
        categories = storageService.loadTodoCategories()
        
        if categories.isEmpty {
            let defaultCategories = [
                TodoCategory(name: "学习", color: "blue", icon: "book"),
                TodoCategory(name: "工作", color: "green", icon: "briefcase"),
                TodoCategory(name: "生活", color: "orange", icon: "house"),
                TodoCategory(name: "其他", color: "gray", icon: "ellipsis.circle")
            ]
            categories = defaultCategories
            saveCategories()
        }
    }
    
    // MARK: - 增删改查
    
    func add(_ item: TodoItem) {
        items.append(item)
        scheduleReminderIfNeeded(for: item)
        saveItems()
    }
    
    func update(_ item: TodoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var updated = item
            updated.updatedAt = Date()
            items[index] = updated
            scheduleReminderIfNeeded(for: updated)
            saveItems()
        }
    }
    
    func delete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
        cancelReminder(for: item)
        saveItems()
    }
    
    func delete(_ itemsToDelete: [TodoItem]) {
        for item in itemsToDelete {
            cancelReminder(for: item)
        }
        let ids = Set(itemsToDelete.map { $0.id })
        items.removeAll { ids.contains($0.id) }
        saveItems()
    }
    
    func toggleComplete(_ item: TodoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].status = (items[index].status == .completed) ? .pending : .completed
            items[index].completedAt = (items[index].status == .completed) ? Date() : nil
            items[index].updatedAt = Date()
            
            if items[index].status == .completed {
                stopPomodoroForTodo(items[index])
            }
            saveItems()
        }
    }
    
    func togglePin(_ item: TodoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].isPinned.toggle()
            items[index].updatedAt = Date()
            saveItems()
        }
    }
    
    // MARK: - 分类管理
    
    func addCategory(name: String, color: String = "blue", icon: String = "folder") {
        let category = TodoCategory(name: name, color: color, icon: icon)
        categories.append(category)
        saveCategories()
    }
    
    func deleteCategory(_ category: TodoCategory) {
        categories.removeAll { $0.id == category.id }
        // 将该分类下的待办的分类改为"默认"
        for index in items.indices where items[index].category == category.name {
            items[index].category = "默认"
        }
        saveCategories()
        saveItems()
    }
    
    // MARK: - 搜索与筛选
    
    func searchItems(query: String, status: TodoStatus? = nil, category: String? = nil) -> [TodoItem] {
        var results = items
        
        if let status = status {
            results = results.filter { $0.status == status }
        }
        
        if let category = category, !category.isEmpty {
            results = results.filter { $0.category == category }
        }
        
        if !query.isEmpty {
            results = results.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                $0.description.localizedCaseInsensitiveContains(query) ||
                $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            }
        }
        
        return sortItems(results)
    }
    
    /// 排序：置顶 > 紧急 > 高 > 中 > 低 > 截止日期 > 创建时间
    func sortItems(_ items: [TodoItem]) -> [TodoItem] {
        return items.sorted { item1, item2 in
            if item1.isPinned != item2.isPinned {
                return item1.isPinned
            }
            if item1.priority.sortValue != item2.priority.sortValue {
                return item1.priority.sortValue < item2.priority.sortValue
            }
            if let d1 = item1.dueDate, let d2 = item2.dueDate {
                return d1 < d2
            }
            if item1.dueDate != nil && item2.dueDate == nil {
                return true
            }
            if item1.dueDate == nil && item2.dueDate != nil {
                return false
            }
            return item1.createdAt > item2.createdAt
        }
    }
    
    // MARK: - 番茄钟集成
    
    /// 为待办启动番茄钟
    func startPomodoroForTodo(_ item: TodoItem) {
        // 如果有正在运行的番茄钟，先停止并记录
        if pomodoroService.isRunning {
            stopPomodoroForCurrentTodo()
        }
        
        pomodoroService.startForTodo(todoID: item.id, todoTitle: item.title)
        
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].status = .inProgress
            let session = TodoPomodoroSession(startTime: Date())
            items[index].pomodoroSessions.append(session)
            items[index].linkedTodoID = item.id
            saveItems()
        }
    }
    
    /// 停止当前待办的番茄钟并记录时间
    func stopPomodoroForCurrentTodo() {
        if let linkedID = pomodoroService.linkedTodoID,
           let index = items.firstIndex(where: { $0.id == linkedID }) {
            // 累加番茄钟专注时间
            if let lastSession = items[index].pomodoroSessions.last, lastSession.endTime == nil {
                let duration = Date().timeIntervalSince(lastSession.startTime)
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].endTime = Date()
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].duration += duration
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].completed = pomodoroService.sessionsCompleted > 0
                items[index].totalFocusedSeconds += duration
            }
            saveItems()
        }
        pomodoroService.unlinkTodo()
    }
    
    func stopPomodoroForTodo(_ item: TodoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if let lastSession = items[index].pomodoroSessions.last, lastSession.endTime == nil {
                let duration = Date().timeIntervalSince(lastSession.startTime)
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].endTime = Date()
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].duration += duration
                items[index].totalFocusedSeconds += duration
            }
            saveItems()
        }
    }
    
    /// 记录待办的累计处理时间（手动开始/停止）
    func startTimeRecord(for item: TodoItem, note: String = "") {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let record = TodoTimeRecord(startTime: Date(), note: note)
            items[index].timeRecords.append(record)
            saveItems()
        }
    }
    
    func stopTimeRecord(for item: TodoItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            if let lastRecord = items[index].timeRecords.last, lastRecord.endTime == nil {
                let duration = Date().timeIntervalSince(lastRecord.startTime)
                items[index].timeRecords[items[index].timeRecords.count - 1].endTime = Date()
                items[index].timeRecords[items[index].timeRecords.count - 1].duration += duration
                items[index].totalElapsedSeconds += duration
            }
            saveItems()
        }
    }
    
    // MARK: - 提醒
    
    /// 尝试安排待办提醒。
    ///
    /// `NotificationService` 提供的 async 入口会等待系统 `add` 的真实结果；这里
    /// 只把结果转换后返回，不把“请求已提交”当成“提醒已启用”。明确传入
    /// `requestAuthorization: false`，所以后台保存/恢复路径不会主动弹权限框；
    /// 权限请求只由用户主动开启提醒的调用方负责。
    @discardableResult
    func scheduleReminder(for item: TodoItem) async -> Result<Void, TodoReminderSchedulingError> {
        guard let reminderTime = item.reminderTime else {
            cancelReminder(for: item)
            let result: Result<Void, TodoReminderSchedulingError> = .success(())
            lastReminderSchedulingResult = result
            return result
        }
        
        guard reminderTime > Date() else {
            cancelReminder(for: item)
            let result: Result<Void, TodoReminderSchedulingError> = .failure(.invalidReminderTime)
            lastReminderSchedulingResult = result
            return result
        }
        
        // 完成任务不应保留待发送提醒；清除后视为没有提醒需要安排。
        guard item.status != .completed else {
            cancelReminder(for: item)
            let result: Result<Void, TodoReminderSchedulingError> = .success(())
            lastReminderSchedulingResult = result
            return result
        }
        
        let notificationResult = await NotificationService.shared.scheduleTodoReminderAsync(
            item: item,
            at: reminderTime,
            requestAuthorization: false
        )
        let result: Result<Void, TodoReminderSchedulingError>
        switch notificationResult {
        case .success:
            result = .success(())
        case .skipped(let reason):
            // 对“启用提醒”来说，skip 也不能伪装成成功。
            result = .failure(.schedulingFailed(reason))
        case .failure(let failure):
            switch failure.reason {
            case .authorizationRequired, .authorizationDenied, .systemRestricted:
                result = .failure(.notificationsNotAuthorized)
            case .invalidRequest:
                result = .failure(.invalidReminderTime)
            case .tooManyNotifications, .addFailed, .settingsPersistenceFailed:
                result = .failure(.schedulingFailed(failure.message))
            }
        }
        
        lastReminderSchedulingResult = result
        if case .failure = result {
            print("[TodoService] 安排待办提醒失败：\(item.id.uuidString)")
        }
        return result
    }
    
    /// 旧的同步入口仍服务于列表的快速保存；实际结果通过上面的 async API 暴露。
    private func scheduleReminderIfNeeded(for item: TodoItem) {
        Task { [weak self] in
            guard let self else { return }
            let result = await self.scheduleReminder(for: item)
            if case .failure = result {
                // 服务内部也不保留一个看似已启用的提醒。调用方仍应使用 async API
                // 提前拿到失败原因并保持开关关闭，避免 UI 继续显示“已启用”。
                clearFailedReminder(for: item)
            }
        }
    }
    
    private func clearFailedReminder(for attemptedItem: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == attemptedItem.id }),
              items[index].reminderTime == attemptedItem.reminderTime else {
            return
        }
        items[index].reminderTime = nil
        items[index].updatedAt = Date()
        saveItems()
    }
    
    private func cancelReminder(for item: TodoItem) {
        NotificationService.shared.cancelTodoReminder(todoID: item.id)
    }
    
    func rescheduleAllReminders() {
        for item in items {
            scheduleReminderIfNeeded(for: item)
        }
    }
    
    // MARK: - 统计
    
    /// 待办统计口径：
    /// - `totalCount` 是该时间段内有活动的去重任务数。活动包括期间创建、期间完成，
    ///   或期间有番茄钟/手动计时的增量；因此进行中的任务也能进入“进行中”统计。
    /// - `completedCount` 只按 `completedAt` 落在该时间段内计数，不读取当前状态。
    ///   旧数据缺少 `completedAt` 时仅用 `updatedAt` 做兼容性近似，并明确注明。
    /// - 时长来自 `pomodoroSessions` / `timeRecords` 的历史区间，按与统计桶的重叠
    ///   部分计算，不再把任务当前累计时长整包归到创建日。
    /// - 旧数据若只有累计值而没有历史记录，无法恢复真实的每日增量；这里仅以一个
    ///   合成的累计区间作过渡 fallback，并优先使用已有的历史记录。
    func statistics(
        for period: TodoStatisticsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [TodoStatisticsData] {
        var result: [TodoStatisticsData] = []
        let intervals = statisticsIntervals(for: period, now: now, calendar: calendar)
        
        for interval in intervals {
            var activeItems: [(completion: Date?, focused: TimeInterval, elapsed: TimeInterval)] = []
            
            for item in items {
                let completion = completionDate(for: item)
                let focused = focusedSeconds(
                    for: item,
                    from: interval.start,
                    to: interval.end,
                    now: now
                )
                let elapsed = elapsedSeconds(
                    for: item,
                    from: interval.start,
                    to: interval.end,
                    now: now
                )
                let createdInPeriod = date(instant: item.createdAt, liesIn: interval)
                let completedInPeriod = completion.map {
                    date(instant: $0, liesIn: interval)
                } ?? false
                let hasTiming = focused > 0 || elapsed > 0
                
                guard createdInPeriod || completedInPeriod || hasTiming else {
                    continue
                }
                activeItems.append((completion, focused, elapsed))
            }
            
            let completedCount = activeItems.reduce(into: 0) { count, activity in
                if let completion = activity.completion,
                   date(instant: completion, liesIn: interval) {
                    count += 1
                }
            }
            let focused = activeItems.reduce(0.0) { $0 + $1.focused }
            let elapsed = activeItems.reduce(0.0) { $0 + $1.elapsed }
            
            result.append(TodoStatisticsData(
                periodStart: interval.start,
                periodLabel: interval.label,
                completedCount: completedCount,
                totalCount: activeItems.count,
                focusedSeconds: focused,
                elapsedSeconds: elapsed
            ))
        }
        
        // 生成时是从新到旧，展示时保持原有从旧到新的顺序。
        return result.reversed()
    }
    
    private func statisticsIntervals(
        for period: TodoStatisticsPeriod,
        now: Date,
        calendar: Calendar
    ) -> [(start: Date, end: Date, label: String)] {
        var intervals: [(start: Date, end: Date, label: String)] = []
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        
        switch period {
        case .day:
            formatter.dateFormat = "MM-dd"
            for offset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: -offset, to: now),
                      let day = calendar.dateInterval(of: .day, for: date) else {
                    continue
                }
                intervals.append((day.start, day.end, formatter.string(from: day.start)))
            }
            
        case .week:
            formatter.dateFormat = "MM-dd"
            guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return intervals
            }
            for offset in 0..<4 {
                guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeek.start),
                      let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else {
                    continue
                }
                intervals.append((
                    start,
                    end,
                    "\(formatter.string(from: start))~\(formatter.string(from: end))"
                ))
            }
            
        case .month:
            formatter.dateFormat = "yyyy-MM"
            guard let currentMonth = calendar.dateInterval(of: .month, for: now) else {
                return intervals
            }
            for offset in 0..<6 {
                guard let start = calendar.date(byAdding: .month, value: -offset, to: currentMonth.start),
                      let end = calendar.date(byAdding: .month, value: 1, to: start) else {
                    continue
                }
                intervals.append((start, end, formatter.string(from: start)))
            }
        }
        
        return intervals
    }
    
    private func date(instant: Date, liesIn interval: (start: Date, end: Date, label: String)) -> Bool {
        instant >= interval.start && instant < interval.end
    }
    
    private func completionDate(for item: TodoItem) -> Date? {
        if let completedAt = item.completedAt {
            return completedAt
        }
        
        // `completedAt` 是可选 Codable 字段，旧数据可以正常解码为 nil。对于这类
        // 旧数据只能用最后更新时间近似完成日；新数据始终优先使用真实完成时间。
        if item.status == .completed {
            return item.updatedAt
        }
        return nil
    }
    
    private func focusedSeconds(
        for item: TodoItem,
        from periodStart: Date,
        to periodEnd: Date,
        now: Date
    ) -> TimeInterval {
        if !item.pomodoroSessions.isEmpty {
            return item.pomodoroSessions.reduce(0.0) { partial, session in
                partial + overlapDuration(
                    from: session.startTime,
                    to: session.endTime,
                    periodStart: periodStart,
                    periodEnd: periodEnd,
                    now: now
                )
            }
        }
        
        return legacyDuration(
            item.totalFocusedSeconds,
            for: item,
            from: periodStart,
            to: periodEnd,
            now: now
        )
    }
    
    private func elapsedSeconds(
        for item: TodoItem,
        from periodStart: Date,
        to periodEnd: Date,
        now: Date
    ) -> TimeInterval {
        if !item.timeRecords.isEmpty {
            return item.timeRecords.reduce(0.0) { partial, record in
                partial + overlapDuration(
                    from: record.startTime,
                    to: record.endTime,
                    periodStart: periodStart,
                    periodEnd: periodEnd,
                    now: now
                )
            }
        }
        
        return legacyDuration(
            item.totalElapsedSeconds,
            for: item,
            from: periodStart,
            to: periodEnd,
            now: now
        )
    }
    
    private func overlapDuration(
        from start: Date,
        to end: Date?,
        periodStart: Date,
        periodEnd: Date,
        now: Date
    ) -> TimeInterval {
        // 未结束的记录按“现在”截断，既能看到进行中时长，也不会把未来时间算进去。
        let effectiveEnd = min(end ?? now, now)
        guard effectiveEnd > start else { return 0 }
        
        let overlapStart = max(start, periodStart)
        let overlapEnd = min(effectiveEnd, periodEnd)
        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }
    
    private func legacyDuration(
        _ total: TimeInterval,
        for item: TodoItem,
        from periodStart: Date,
        to periodEnd: Date,
        now: Date
    ) -> TimeInterval {
        guard total.isFinite, total > 0 else { return 0 }
        
        // 没有历史区间的旧记录无法知道真实发生日。完成过的记录优先以真实完成时间
        // 为终点（没有该字段时才退回最后更新时间）；进行中的记录以当前时间为终点，
        // 形成一个透明标注的过渡近似。
        let end: Date
        if item.status == .completed {
            end = min(item.completedAt ?? item.updatedAt, now)
        } else {
            end = now
        }
        let start = end.addingTimeInterval(-total)
        return overlapDuration(
            from: start,
            to: end,
            periodStart: periodStart,
            periodEnd: periodEnd,
            now: now
        )
    }
    
    // MARK: - 持久化
    
    private func saveItems() {
        storageService.saveTodoItems(items)
    }
    
    private func saveCategories() {
        storageService.saveTodoCategories(categories)
    }
}

// 扩展 PomodoroTimer 以支持与待办关联
extension PomodoroTimer {
    private static var currentTodoIDKey: UInt8 = 0
    
    var currentTodoID: UUID? {
        get {
            return objc_getAssociatedObject(self, &PomodoroTimer.currentTodoIDKey) as? UUID
        }
        set {
            objc_setAssociatedObject(self, &PomodoroTimer.currentTodoIDKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}
