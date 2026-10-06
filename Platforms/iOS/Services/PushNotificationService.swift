import Foundation
import UserNotifications
import SwiftUI

@MainActor
class PushNotificationService: NSObject, ObservableObject {
    @Published var deviceToken: String?
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    static let shared = PushNotificationService()

    /// 通知点击后的路由回调。
    ///
    /// macOS 用 `NotificationRouter` + `SharedAppStateProxy` 定位到具体窗口；
    /// iOS 由 SwiftUI 的选中标签驱动，因此这里让 `AppState_iOS` 直接接管。
    /// `userInfo` 只放实体 ID 与种类，不含私密正文。
    var onNotificationTapped: (([String: Any]) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .provisional])
            authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            if granted, supportsRemotePush {
                await registerForRemoteNotifications()
            }
            return granted
        } catch {
            errorMessage = "请求通知权限失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 当前签名是否支持**远程**推送。
    ///
    /// 远程推送需要描述文件里带 `aps-environment`，也就是要声明
    /// `com.apple.developer.push-notifications`。个人（免费）开发者账号在
    /// 本工程当前配置下拿不到该项（见 project.yml 的 entitlements 说明），
    /// 此时 `registerForRemoteNotifications()` 不会崩溃，但也不会回调
    /// device token——与其发起一个注定无果的请求，不如直接跳过。
    ///
    /// 注意：这**不影响本地通知**。本地提醒（待办、习惯、纪念日、复习、番茄钟）
    /// 由 `NotificationService_iOS` 走 `UNUserNotificationCenter`，
    /// 不需要任何 entitlement，功能完整可用。
    private var supportsRemotePush: Bool {
        // 判据：aps-environment 只存在于带推送能力的描述文件里。
        // 读取 App 自身的 provisioning profile 是最可靠的运行时判据。
        guard let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let profile = try? Data(contentsOf: URL(fileURLWithPath: profilePath))
        else {
            // 模拟器 / 侧载包没有描述文件：按不支持处理。
            return false
        }
        // plist 是二进制或 XML，二进制格式里字符串以字面量形式存在，
        // 因此直接按字节匹配即可，无需完整解析。
        return profile.range(of: Data("aps-environment".utf8)) != nil
    }

    private func registerForRemoteNotifications() async {
        await UIApplication.shared.registerForRemoteNotifications()
    }

    func getDeviceToken() async -> String? {
        return deviceToken
    }

    func handleDeviceToken(_ token: Data) {
        let tokenString = token.map { String(format: "%02.2hhx", $0) }.joined()
        deviceToken = tokenString
        // 发送到服务器
        Task { await sendTokenToServer(tokenString) }
    }

    func handleRegistrationError(_ error: Error) {
        errorMessage = "注册远程通知失败：\(error.localizedDescription)"
    }

    private func sendTokenToServer(_ token: String) async {
        // TODO: 发送到后端服务器
        // 如果有后端 API，在这里调用
    }

    // 本地通知调度（用于复习提醒、习惯打卡、纪念日等）
    func scheduleLocalNotification(
        id: String,
        title: String,
        body: String,
        date: Date,
        repeats: Bool = false,
        userInfo: [String: Any] = [:],
        categoryIdentifier: String? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = 1
        content.userInfo = userInfo
        if let categoryIdentifier = categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }

        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: repeats)

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                Task { @MainActor in self?.errorMessage = "调度通知失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelNotification(id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }

    func cancelAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    func getPendingNotifications() async -> [UNNotificationRequest] {
        return await UNUserNotificationCenter.current().pendingNotificationRequests()
    }

    // 批量调度复习提醒
    func scheduleReviewReminders(_ plans: [ReviewPlan]) {
        for plan in plans {
            // `ReviewPlan` 以 `dailyPlans`（每日任务组）组织，
            // 提醒按具体任务（`ReviewTask`）逐条安排。
            for dailyPlan in plan.dailyPlans {
                for task in dailyPlan.tasks {
                    // 正文只给科目 + 任务标题，不带知识点等私密细节。
                    scheduleLocalNotification(
                        id: NotificationIdentifiers.reviewTask(task.id),
                        title: "复习提醒",
                        body: "\(plan.subject) · \(task.title)",
                        date: dailyPlan.date,
                        userInfo: [
                            "kind": "review",
                            "planID": plan.id.uuidString,
                            "taskID": task.id.uuidString
                        ]
                    )
                }
            }
        }
    }

    // 批量调度习惯打卡提醒
    func scheduleHabitReminders(_ habits: [Habit]) {
        for habit in habits {
            // `Habit.reminderTime` 为 nil 即代表未开启提醒；
            // `reminderEnabled` 不是模型字段，提醒开关就编码在 `reminderTime` 上。
            guard let reminderTime = habit.reminderTime else { continue }
            let calendar = Calendar.current
            let now = Date()
            for dayOffset in 0..<30 { // 未来 30 天
                let targetDate = calendar.date(byAdding: .day, value: dayOffset, to: now)!
                var components = calendar.dateComponents([.year, .month, .day], from: targetDate)
                components.hour = calendar.component(.hour, from: reminderTime)
                components.minute = calendar.component(.minute, from: reminderTime)
                if let date = calendar.date(from: components), date > now {
                    let id = "habit_\(habit.id.uuidString)_\(date.timeIntervalSince1970)"
                    scheduleLocalNotification(
                        id: id,
                        title: "习惯打卡",
                        body: "别忘了今天的「\(habit.name)」哦！",
                        date: date,
                        repeats: false,
                        userInfo: ["type": "habit", "habitId": habit.id.uuidString]
                    )
                }
            }
        }
    }

    // 调度纪念日提醒
    //
    // `Anniversary` 没有独立的开关字段：`leadTimeDays <= 0` 表示不提醒。
    // 提前量与 `AnniversaryService` 保持一致，提醒正文只给相距天数，
    // 不带纪念日名称或备注，避免在锁屏上泄露隐私。
    func scheduleAnniversaryReminders(_ anniversaries: [Anniversary]) {
        let calendar = Calendar.current
        let now = Date()

        for anniversary in anniversaries {
            guard anniversary.leadTimeDays > 0 else { continue }

            let occurrence = anniversary.nextOccurrence(after: now)
            guard let reminderDate = calendar.date(
                byAdding: .day,
                value: -anniversary.leadTimeDays,
                to: occurrence
            ), reminderDate > now else { continue }

            let daysUntil = anniversary.daysUntilNextOccurrence(reference: now, calendar: calendar)
            let body: String
            switch daysUntil {
            case 0: body = "就是今天"
            case 1: body = "就是明天"
            default: body = "还有 \(daysUntil) 天"
            }

            scheduleLocalNotification(
                id: NotificationIdentifiers.anniversary(anniversary.id),
                title: "纪念日提醒",
                body: body,
                date: reminderDate,
                userInfo: [
                    "kind": "anniversary",
                    "anniversaryID": anniversary.id.uuidString,
                    "occurrenceDate": Anniversary.key(for: occurrence)
                ]
            )
        }
    }

    // 番茄钟完成通知
    func schedulePomodoroCompletionNotification(duration: Int) {
        let content = UNMutableNotificationContent()
        content.title = "番茄钟完成"
        content.body = "恭喜！你已专注 \(duration) 分钟。"
        content.sound = .default
        content.categoryIdentifier = "POMODORO_COMPLETE"

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "pomodoro_complete_\(Date().timeIntervalSince1970)", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // 关键警报（需要特殊权限）
    func scheduleCriticalAlert(id: String, title: String, body: String, date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.defaultCritical
        content.interruptionLevel = .critical

        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
}

extension PushNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // App 在前台时也显示通知
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        // 处理通知点击：交给 AppState 决定跳到哪个标签页。
        // CloudKit/系统通知的 userInfo 是 `[AnyHashable: Any]`，转成 `[String: Any]`
        // 才能交给 AppState 的路由函数。
        let raw = response.notification.request.content.userInfo
        let userInfo = raw.reduce(into: [String: Any]()) { result, entry in
            if let key = entry.key as? String { result[key] = entry.value }
        }
        Task { @MainActor in
            PushNotificationService.shared.onNotificationTapped?(userInfo)
        }
        completionHandler()
    }
}

// AppDelegate 扩展方法（在 AppDelegate 中调用）
extension PushNotificationService {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        handleDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        handleRegistrationError(error)
    }
}