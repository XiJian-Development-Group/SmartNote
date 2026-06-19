import Foundation
import UserNotifications

class NotificationService: ObservableObject {
    static let shared = NotificationService()
    
    @Published var isAuthorized = false
    @Published var dailyNotificationEnabled = false
    @Published var notificationTime: Date = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    
    private var notificationTimer: Timer?
    private let storageService = StorageService()
    
    private init() {
        loadSettings()
        checkAuthorization()
    }
    
    private func loadSettings() {
        let settings = storageService.loadSettings()
        dailyNotificationEnabled = settings.reminderEnabled
    }
    
    private func saveSettings(_ enabled: Bool) {
        dailyNotificationEnabled = enabled
        var settings = storageService.loadSettings()
        settings.reminderEnabled = enabled
        storageService.saveSettings(settings)
    }
    
    func checkAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.isAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }
    
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await MainActor.run {
                self.isAuthorized = granted
            }
            return granted
        } catch {
            print("Notification authorization error: \(error)")
            return false
        }
    }
    
    func setDailyNotification(enabled: Bool, time: Date? = nil) async {
        if enabled {
            let authorized = await requestAuthorization()
            guard authorized else { return }
            
            if let time = time {
                notificationTime = time
            }
            
            await scheduleDailyNotification()
        } else {
            cancelDailyNotification()
        }
        
        saveSettings(enabled)
    }
    
    func updateNotificationTime(_ time: Date) async {
        notificationTime = time
        if dailyNotificationEnabled {
            await scheduleDailyNotification()
        }
    }
    
    private func scheduleDailyNotification() async {
        cancelDailyNotification()
        
        let content = UNMutableNotificationContent()
        content.title = "📚 智学笔记 - 今日学习提醒"
        content.body = "是时候开始今天的复习计划了！点击查看今日任务。"
        content.sound = .default
        content.badge = 1
        
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: notificationTime)
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "dailyStudyReminder",
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
            print("Daily notification scheduled at \(components.hour ?? 0):\(components.minute ?? 0)")
        } catch {
            print("Error scheduling notification: \(error)")
        }
    }
    
    func cancelDailyNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["dailyStudyReminder"])
    }
    
    func sendStudyPlanNotification(plans: [ReviewPlan]) async {
        guard isAuthorized else { return }
        
        let today = Calendar.current.startOfDay(for: Date())
        let todayPlans = plans.filter { plan in
            plan.dailyPlans.contains { dailyPlan in
                Calendar.current.isDate(dailyPlan.date, inSameDayAs: today)
            }
        }
        
        guard !todayPlans.isEmpty else { return }
        
        let totalTasks = todayPlans.flatMap { $0.dailyPlans }
            .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
            .flatMap { $0.tasks }
            .count
        
        let completedTasks = todayPlans.flatMap { $0.dailyPlans }
            .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
            .flatMap { $0.tasks }
            .filter { $0.isCompleted }
            .count
        
        let remainingTasks = totalTasks - completedTasks
        
        guard remainingTasks > 0 else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "📚 今日复习进度"
        content.body = "你还有 \(remainingTasks) 个复习任务未完成，坚持就是胜利！"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "studyProgress_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Error sending progress notification: \(error)")
        }
    }
    
    func sendTaskReminderNotification(task: ReviewTask, plan: ReviewPlan) async {
        guard isAuthorized else { return }
        
        var body = "现在开始复习：\(task.title)"
        if !task.description.isEmpty {
            body += "\n\(task.description)"
        }
        
        let content = UNMutableNotificationContent()
        content.title = "⏰ 复习任务提醒"
        content.body = body
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "task_\(task.id.uuidString)",
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Error sending task reminder: \(error)")
        }
    }
    
    // MARK: - 待办提醒
    
    /// 为待办事项安排提醒
    func scheduleTodoReminder(item: TodoItem, at date: Date) {
        cancelTodoReminder(todoID: item.id)
        
        let content = UNMutableNotificationContent()
        content.title = "📋 待办提醒"
        var body = item.title
        if !item.description.isEmpty {
            body += "\n\(item.description)"
        }
        content.body = body
        content.sound = .default
        content.userInfo = ["todoID": item.id.uuidString]
        
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "todo_\(item.id.uuidString)",
            content: content,
            trigger: trigger
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling todo reminder: \(error)")
            }
        }
    }
    
    /// 取消待办提醒
    func cancelTodoReminder(todoID: UUID) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["todo_\(todoID.uuidString)"]
        )
    }
    
    /// 立即发送待办提醒（应用内提醒）
    func sendImmediateTodoNotification(title: String, body: String) async {
        guard isAuthorized else { return }
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        let request = UNNotificationRequest(
            identifier: "todoImmediate_\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("Error sending immediate todo notification: \(error)")
        }
    }
}
