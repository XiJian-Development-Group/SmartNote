import Foundation
import Combine
import UserNotifications

/// 纪念日仓库
final class AnniversaryService: ObservableObject {

    @Published private(set) var items: [Anniversary] = []

    private let fileURL: URL
    private let storage: StorageService

    init(storage: StorageService = StorageService()) {
        self.storage = storage
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
        save()
    }

    func update(_ a: Anniversary) {
        if let idx = items.firstIndex(where: { $0.id == a.id }) {
            items[idx] = a
            save()
        }
    }

    /// 计算下一次通知：若距离发生 ≤ leadTimeDays，则认为应当推送
    func shouldNotify(_ item: Anniversary, today: Date = Date()) -> Bool {
        let days = item.daysUntilNextOccurrence(reference: today)
        if days < 0 || days > item.leadTimeDays { return false }
        let key = Anniversary.key(for: item.nextOccurrence(after: today) - TimeInterval(days * 86_400))
        if item.lastNotifiedYearMonthDayKey == key { return false }
        return true
    }

    /// 把所有"该通知的"纪念日打包推送
    @MainActor
    func checkAndRequestPermissionAndNotify(today: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        for item in items where shouldNotify(item, today: today) {
            await postNotification(for: item, today: today)
            var updated = item
            let next = item.nextOccurrence(after: today)
            updated.lastNotifiedYearMonthDayKey = Anniversary.key(for: next)
            update(updated)
        }
    }

    private func postNotification(for item: Anniversary, today: Date) async {
        let content = UNMutableNotificationContent()
        content.title = "提醒：\(item.name)"
        let days = item.daysUntilNextOccurrence(reference: today)
        if days == 0 {
            content.body = "就是今天！\(item.note)"
        } else if days > 0 {
            content.body = "还有 \(days) 天。\(item.note)"
        }
        content.sound = .default
        // 1 秒内推送
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: "anniversary-\(item.id.uuidString)", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(req)
    }
}
