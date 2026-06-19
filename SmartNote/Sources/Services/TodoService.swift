import Foundation
import SwiftUI
import Combine

/// 待办服务：单例，负责待办项的增删改查、持久化、搜索筛选、分类管理
@MainActor
class TodoService: ObservableObject {
    static let shared = TodoService()
    
    @Published var items: [TodoItem] = []
    @Published var categories: [TodoCategory] = []
    
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
        
        pomodoroService.start(subject: item.title)
        
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
        if let linkedID = pomodoroService.currentTodoID,
           let index = items.firstIndex(where: { $0.id == linkedID }) {
            // 累加番茄钟专注时间
            if let lastSession = items[index].pomodoroSessions.last {
                let duration = Date().timeIntervalSince(lastSession.startTime)
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].endTime = Date()
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].duration += duration
                items[index].pomodoroSessions[items[index].pomodoroSessions.count - 1].completed = pomodoroService.sessionsCompleted > 0
                items[index].totalFocusedSeconds += duration
            }
            saveItems()
        }
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
    
    private func scheduleReminderIfNeeded(for item: TodoItem) {
        guard let reminderTime = item.reminderTime,
              reminderTime > Date(),
              item.status != .completed else {
            cancelReminder(for: item)
            return
        }
        
        NotificationService.shared.scheduleTodoReminder(item: item, at: reminderTime)
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
    
    func statistics(for period: TodoStatisticsPeriod) -> [TodoStatisticsData] {
        let calendar = Calendar.current
        let now = Date()
        var result: [TodoStatisticsData] = []
        
        switch period {
        case .day:
            // 最近 7 天
            for i in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
                let startOfDay = calendar.startOfDay(for: date)
                guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { continue }
                let dayItems = items.filter { $0.createdAt >= startOfDay && $0.createdAt < endOfDay }
                let completed = dayItems.filter { $0.status == .completed }
                let focused = completed.reduce(0.0) { $0 + $1.totalFocusedSeconds }
                let elapsed = completed.reduce(0.0) { $0 + $1.totalElapsedSeconds }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd"
                
                result.append(TodoStatisticsData(
                    periodStart: startOfDay,
                    periodLabel: formatter.string(from: startOfDay),
                    completedCount: completed.count,
                    totalCount: dayItems.count,
                    focusedSeconds: focused,
                    elapsedSeconds: elapsed
                ))
            }
            
        case .week:
            // 最近 4 周
            for i in 0..<4 {
                guard let endDate = calendar.date(byAdding: .weekOfYear, value: -i, to: now) else { continue }
                let endOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: endDate)) ?? endDate
                guard let startOfWeek = calendar.date(byAdding: .day, value: -7, to: endOfWeek) else { continue }
                let weekItems = items.filter { $0.createdAt >= startOfWeek && $0.createdAt < endOfWeek }
                let completed = weekItems.filter { $0.status == .completed }
                let focused = completed.reduce(0.0) { $0 + $1.totalFocusedSeconds }
                let elapsed = completed.reduce(0.0) { $0 + $1.totalElapsedSeconds }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd"
                
                result.append(TodoStatisticsData(
                    periodStart: startOfWeek,
                    periodLabel: "\(formatter.string(from: startOfWeek))~\(formatter.string(from: endOfWeek))",
                    completedCount: completed.count,
                    totalCount: weekItems.count,
                    focusedSeconds: focused,
                    elapsedSeconds: elapsed
                ))
            }
            
        case .month:
            // 最近 6 个月
            for i in 0..<6 {
                guard let endDate = calendar.date(byAdding: .month, value: -i, to: now) else { continue }
                let components = calendar.dateComponents([.year, .month], from: endDate)
                guard let startOfMonth = calendar.date(from: components),
                      let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) else { continue }
                let monthItems = items.filter { $0.createdAt >= startOfMonth && $0.createdAt < endOfMonth }
                let completed = monthItems.filter { $0.status == .completed }
                let focused = completed.reduce(0.0) { $0 + $1.totalFocusedSeconds }
                let elapsed = completed.reduce(0.0) { $0 + $1.totalElapsedSeconds }
                
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM"
                
                result.append(TodoStatisticsData(
                    periodStart: startOfMonth,
                    periodLabel: formatter.string(from: startOfMonth),
                    completedCount: completed.count,
                    totalCount: monthItems.count,
                    focusedSeconds: focused,
                    elapsedSeconds: elapsed
                ))
            }
        }
        
        return result.reversed()
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
