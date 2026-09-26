import Foundation
import Combine
import UserNotifications

/// 纪念日仓库
final class AnniversaryService: ObservableObject {

    @Published private(set) var items: [Anniversary] = []
    @Published private(set) var lastNotificationResults: [NotificationOperationResult] = []

    private let fileURL: URL
    private let storage: StorageService
    private let notification: NotificationService

    init(
        storage: StorageService = StorageService(),
        notification: NotificationService = NotificationService.shared
    ) {
        self.storage = storage
        self.notification = notification
        self.fileURL = storage.appSupportURL.appendingPathComponent("anniversaries.json")
        load()
    }

    func load() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            items = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([Anniversary].self, from: data)
        } catch {
            print("纪念日读取失败：\(error)")
            items = []
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("纪念日保存失败：\(error)")
        }
    }

    func add(_ a: Anniversary) {
        items.insert(a, at: 0)
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        notification.removePendingNotification(identifier: NotificationIdentifiers.anniversary(id))
        save()
    }

    func update(_ a: Anniversary) {
        if let idx = items.firstIndex(where: { $0.id == a.id }) {
            items[idx] = a
            save()
        }
    }

    /// 计算下一次通知：若距离发生 ≤ leadTimeDays，则认为应当推送。
    func shouldNotify(_ item: Anniversary, today: Date = Date()) -> Bool {
        let days = item.daysUntilNextOccurrence(reference: today)
        if days < 0 || days > item.leadTimeDays { return false }

        // 标记的是“发生日”，而不是今天。否则提前 3 天提醒时每次检查都会
        // 产生不同的 key，无法真正去重。
        let occurrence = item.nextOccurrence(after: today)
        let key = Anniversary.key(for: occurrence)
        if item.lastNotifiedYearMonthDayKey == key { return false }
        return true
    }

    /// 用户在界面点击“检查通知”时调用。已有权限只查询，不重复弹框；
    /// 只有用户主动触发且状态为 notDetermined 时才请求权限。
    @MainActor
    @discardableResult
    func checkAndRequestPermissionAndNotify(today: Date = Date()) async -> [NotificationOperationResult] {
        let authorization = await notification.requestAuthorization()
        switch authorization {
        case .success(let status):
            return await notifyEligibleItems(today: today, authorizationStatus: status)
        case .failure(let failure):
            let result = NotificationOperationResult.failure(failure)
            lastNotificationResults = [result]
            return [result]
        }
    }

    /// 启动/后台检查入口：只查询状态，绝不请求权限。
    @MainActor
    @discardableResult
    func checkAndNotify(today: Date = Date()) async -> [NotificationOperationResult] {
        let status = await notification.checkAuthorization()
        guard status.canSendNotifications else {
            let result = NotificationOperationResult.failure(authorizationFailure(for: status))
            lastNotificationResults = [result]
            return [result]
        }
        return await notifyEligibleItems(today: today, authorizationStatus: status)
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

    @MainActor
    private func notifyEligibleItems(
        today: Date,
        authorizationStatus status: NotificationAuthorizationStatus
    ) async -> [NotificationOperationResult] {
        var results: [NotificationOperationResult] = []

        for item in items where shouldNotify(item, today: today) {
            let result = await postNotification(
                for: item,
                today: today,
                authorizationStatus: status
            )
            results.append(result)

            // 只有真实 add 成功才写“已通知”。失败时保持旧值，下一次检查仍会重试。
            if case .success = result {
                var updated = item
                let next = item.nextOccurrence(after: today)
                updated.lastNotifiedYearMonthDayKey = Anniversary.key(for: next)
                update(updated)
            }
        }

        lastNotificationResults = results
        return results
    }

    private func postNotification(
        for item: Anniversary,
        today: Date,
        authorizationStatus status: NotificationAuthorizationStatus
    ) async -> NotificationOperationResult {
        let occurrence = item.nextOccurrence(after: today)
        // 标题和正文都不包含纪念日名称或备注。userInfo 只放 ID 和发生日，
        // 用户点击后由 App 查询详情；当前工程没有通知点击路由，因此不把备注带出。
        // 正文只给出相距天数：既让通知有信息量，也不泄露纪念日名称。
        let daysUntil = item.daysUntilNextOccurrence(reference: today)
        let content = NotificationService.makePrivateContent(
            title: "纪念日提醒",
            body: Self.reminderBody(daysUntil: daysUntil),
            userInfo: [
                "kind": "anniversary",
                "anniversaryID": item.id.uuidString,
                "occurrenceDate": Anniversary.key(for: occurrence)
            ]
        )
        let trigger = Self.makeTrigger(
            occurrence: occurrence,
            leadTimeDays: item.leadTimeDays,
            now: today
        )
        let identifier = NotificationIdentifiers.anniversary(item.id)
        return await notification.submitNotification(
            identifier: identifier,
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: status
        )
    }

    /// 提醒时间 = 发生日往前推 leadTimeDays，当天的 09:00。
    /// 已经到点（或已过）时立即投递，否则排到那一刻。
    ///
    /// 修复前所有命中项都用 `timeInterval: 1`，用户点一次「检查通知」，
    /// 3 天后、5 天后、下周的纪念日会在同一秒一起弹出，
    /// 提前量 `leadTimeDays` 形同虚设。
    static func makeTrigger(
        occurrence: Date,
        leadTimeDays: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> UNNotificationTrigger {
        let days = max(0, leadTimeDays)
        let day = calendar.startOfDay(for: occurrence)
        guard let reminderDay = calendar.date(byAdding: .day, value: -days, to: day) else {
            return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        var components = calendar.dateComponents([.year, .month, .day], from: reminderDay)
        components.hour = Self.reminderHour
        components.minute = 0

        guard let fireDate = calendar.date(from: components), fireDate > now else {
            return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    /// 提醒投递时刻：当天 09:00。早于此点已过则立即投递。
    static let reminderHour: Int = 9

    static func reminderBody(daysUntil: Int) -> String {
        switch daysUntil {
        case ..<0: return "有一项纪念日提醒"
        case 0: return "今天有一项纪念日"
        case 1: return "明天有一项纪念日"
        default: return "\(daysUntil) 天后有一项纪念日"
        }
    }
}
