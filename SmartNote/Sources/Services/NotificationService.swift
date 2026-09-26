import Foundation
import UserNotifications

/// 系统通知授权状态。
///
/// `.provisional` 和 `.ephemeral` 虽然不是完整的用户授权，但系统仍然允许 App
/// 投递通知，因此不能把它们当成“未授权”。
enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    /// 某些系统策略可能只暴露“无法确定”的状态；按不可发送处理。
    case restricted
    case unknown

    init(_ status: UNAuthorizationStatus) {
        // `.ephemeral` is exposed by iOS but marked unavailable on macOS.
        // Keep the domain value in our cross-platform enum and recognize its raw
        // value defensively so a future/system-provided ephemeral state is not
        // mistaken for an unusable unknown state.
        if status.rawValue == 4 {
            self = .ephemeral
            return
        }

        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        @unknown default:
            self = .unknown
        }
    }

    var canSendNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .restricted, .unknown:
            return false
        }
    }

    /// 便于 UI/调用方显示的状态说明（不会把授权状态隐藏成一个 Bool）。
    var displayDescription: String {
        switch self {
        case .notDetermined:
            return "尚未请求通知权限"
        case .denied:
            return "通知权限已被拒绝"
        case .authorized:
            return "已获得通知权限"
        case .provisional:
            return "已获得临时通知权限"
        case .ephemeral:
            return "已获得短暂的临时通知权限"
        case .restricted:
            return "通知被系统策略限制"
        case .unknown:
            return "无法确定通知权限"
        }
    }
}

/// 通知失败的原因。所有面向调用方的说明均为中文，系统原始错误只用于日志分类。
enum NotificationFailureReason: Equatable, Sendable {
    case authorizationRequired
    case authorizationDenied
    case systemRestricted
    case tooManyNotifications
    case invalidRequest
    case addFailed
    case settingsPersistenceFailed

    var defaultMessage: String {
        switch self {
        case .authorizationRequired:
            return "尚未获得通知权限，请先允许通知。"
        case .authorizationDenied:
            return "通知权限已被拒绝，请在系统设置中允许通知。"
        case .systemRestricted:
            return "通知被系统限制，当前无法发送通知。"
        case .tooManyNotifications:
            return "系统通知数量已达上限，无法安排更多通知，请稍后重试。"
        case .invalidRequest:
            return "通知请求无效，请检查提醒时间或内容。"
        case .addFailed:
            return "系统未能安排通知，请稍后重试。"
        case .settingsPersistenceFailed:
            return "通知状态未能保存，请稍后重试。"
        }
    }
}

struct NotificationFailure: Error, Equatable, LocalizedError, Sendable {
    let reason: NotificationFailureReason
    let message: String

    init(reason: NotificationFailureReason, message: String? = nil) {
        self.reason = reason
        self.message = message ?? reason.defaultMessage
    }

    var errorDescription: String? { message }
}

typealias NotificationAuthorizationResult = Result<NotificationAuthorizationStatus, NotificationFailure>

/// 一次通知操作的结果。没有需要发送的通知时使用 `.skipped`，真正的系统错误
/// 使用 `.failure`，不会用成功结果掩盖失败。
enum NotificationOperationResult: Equatable, Sendable {
    case success(identifier: String)
    case skipped(reason: String)
    case failure(NotificationFailure)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failure: NotificationFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }

    var identifier: String? {
        if case .success(let identifier) = self { return identifier }
        return nil
    }
}

typealias NotificationResult = NotificationOperationResult

/// UserNotifications 的最小可注入接口。生产环境使用 `.live`，测试/探针可以
/// 注入假的授权状态、发送闭包和 pending 请求集合，不会向系统投递通知。
struct NotificationCenterClient {
    let authorizationStatus: () async -> NotificationAuthorizationStatus
    let requestAuthorization: () async throws -> Bool
    let add: (UNNotificationRequest) async throws -> Void
    let removePending: ([String]) -> Void
    let pendingIdentifiers: () async -> Set<String>

    init(
        authorizationStatus: @escaping () async -> NotificationAuthorizationStatus,
        requestAuthorization: @escaping () async throws -> Bool,
        add: @escaping (UNNotificationRequest) async throws -> Void,
        removePending: @escaping ([String]) -> Void,
        pendingIdentifiers: @escaping () async -> Set<String> = { [] }
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.add = add
        self.removePending = removePending
        self.pendingIdentifiers = pendingIdentifiers
    }

    static var live: NotificationCenterClient {
        let center = UNUserNotificationCenter.current()
        return NotificationCenterClient(
            authorizationStatus: {
                let settings = await center.notificationSettings()
                return NotificationAuthorizationStatus(settings.authorizationStatus)
            },
            requestAuthorization: {
                try await center.requestAuthorization(options: [.alert, .sound, .badge])
            },
            add: { request in
                try await center.add(request)
            },
            removePending: { identifiers in
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            },
            pendingIdentifiers: {
                await withCheckedContinuation { continuation in
                    center.getPendingNotificationRequests { requests in
                        continuation.resume(returning: Set(requests.map(\.identifier)))
                    }
                }
            }
        )
    }
}

/// 通知请求的稳定标识符规则：
/// - 每日学习：`dailyStudyReminder`
/// - 待办：`todo_<UUID>`，同一待办永远覆盖同一请求
/// - 复习任务：`task_<UUID>`
/// - 习惯：`habit_<UUID>`
/// - 纪念日：`anniversary-<UUID>`
/// - 学习进度：`studyProgress`（同一类进度通知覆盖）
/// - 番茄钟：每次即时事件使用 `pomodoro_<UUID>`，不会被当作可叠加的 pending 提醒
enum NotificationIdentifiers {
    static let dailyStudyReminder = "dailyStudyReminder"
    static let studyProgress = "studyProgress"

    static func todo(_ id: UUID) -> String { "todo_\(id.uuidString)" }
    static func reviewTask(_ id: UUID) -> String { "task_\(id.uuidString)" }
    static func habit(_ id: UUID) -> String { "habit_\(id.uuidString)" }
    static func anniversary(_ id: UUID) -> String { "anniversary-\(id.uuidString)" }
    /// 番茄钟通知标识符。固定为 `pomodoro_current`：
    /// 原实现每次生成新 UUID，通知中心会堆满 `pomodoro_*` 条目。
    /// 配合调用处的 `removeExisting: true`，新通知会替换上一条。
    static func pomodoro() -> String { "pomodoro_current" }
}

final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    /// 兼容现有设置页/调用方的 Bool 状态；它只反映最近一次查询，不用于替代
    /// `authorizationStatus` 的明确结果。
    @Published var isAuthorized = false
    @Published private(set) var authorizationStatus: NotificationAuthorizationStatus = .notDetermined
    @Published var dailyNotificationEnabled = false
    @Published var notificationTime: Date = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()

    /// 最近的明确结果/错误，供轻提示和未来调用方读取。
    @Published private(set) var lastResult: NotificationOperationResult?
    @Published private(set) var lastErrorMessage: String?

    private let storageService: StorageService
    private let center: NotificationCenterClient
    private var persistedReminderEnabled = false

    init(
        storageService: StorageService = StorageService(),
        center: NotificationCenterClient = .live
    ) {
        self.storageService = storageService
        self.center = center
        loadSettings()

        // 初始化只查询状态，绝不主动弹权限框。真正的 requestAuthorization 只由
        // 用户主动开启功能的路径调用。
        Task { [weak self] in
            await self?.reconcileAtStartup()
        }
    }

    private func loadSettings() {
        let settings = storageService.loadSettings()
        persistedReminderEnabled = settings.reminderEnabled
        // 先不把持久化意图当成已安排成功；启动查询确认有权限且存在对应请求后
        // 才在内存中显示为启用。
        dailyNotificationEnabled = false
    }

    private func reconcileAtStartup() async {
        let status = await checkAuthorization()
        guard status.canSendNotifications else {
            await setDailyRuntimeState(false)
            return
        }

        let pending = await center.pendingIdentifiers()
        let actuallyScheduled = persistedReminderEnabled && pending.contains(NotificationIdentifiers.dailyStudyReminder)
        await setDailyRuntimeState(actuallyScheduled)
    }

    // MARK: - Authorization

    /// 只查询系统当前状态，不请求权限。返回值明确区分 provisional/ephemeral。
    @discardableResult
    func checkAuthorization() async -> NotificationAuthorizationStatus {
        let status = await center.authorizationStatus()
        await MainActor.run {
            self.authorizationStatus = status
            self.isAuthorized = status.canSendNotifications
            if !status.canSendNotifications {
                self.dailyNotificationEnabled = false
            }
        }
        return status
    }

    /// 用户主动开启功能时调用。先查询，已有授权不会重复弹框；只有
    /// `.notDetermined` 才会调用系统 requestAuthorization。
    func requestAuthorization() async -> NotificationAuthorizationResult {
        let current = await checkAuthorization()
        if current.canSendNotifications {
            return .success(current)
        }

        guard current == .notDetermined else {
            let failure = authorizationFailure(for: current)
            await record(.failure(failure))
            return .failure(failure)
        }

        do {
            let granted = try await center.requestAuthorization()
            let after = await center.authorizationStatus()
            let resolved: NotificationAuthorizationStatus
            if after.canSendNotifications {
                resolved = after
            } else if granted {
                // 某些系统/测试适配器在 request 回调后不会立即刷新 settings；
                // request 返回 granted 本身就是有效的投递信号。
                resolved = .authorized
            } else {
                resolved = after
            }

            await MainActor.run {
                self.authorizationStatus = resolved
                self.isAuthorized = resolved.canSendNotifications
            }

            guard resolved.canSendNotifications else {
                let failure = authorizationFailure(for: resolved)
                await record(.failure(failure))
                return .failure(failure)
            }
            return .success(resolved)
        } catch {
            let failure = mapNotificationError(error, fallback: .authorizationDenied)
            await record(.failure(failure))
            return .failure(failure)
        }
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

    // MARK: - Result and low-level submission

    /// 创建一个不包含私密内容的基础通知。任务标题、描述、习惯名称、纪念日备注
    /// 等只能放进 App 内部的 ID/路由信息，不能进入 title/body。
    static func makePrivateContent(
        title: String,
        body: String,
        userInfo: [String: Any] = [:]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.userInfo = userInfo
        // macOS 没有可可靠隐藏锁屏预览的独立属性；passive + 中性正文是本项目的
        // 可行方案，避免敏感内容以横幅/抢占式提醒出现在锁屏上。
        content.interruptionLevel = .passive
        return content
    }

    /// 安排/投递一个通知。调用方可以传入刚刚获得的授权状态，避免重复查询；
    /// 若不传则只查询状态，绝不会隐式请求权限。
    @discardableResult
    func submitNotification(
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger?,
        removeExisting: Bool = true,
        authorizationStatus statusOverride: NotificationAuthorizationStatus? = nil
    ) async -> NotificationOperationResult {
        guard !identifier.isEmpty else {
            let result = NotificationOperationResult.failure(
                NotificationFailure(reason: .invalidRequest, message: "通知标识符为空，无法安排通知。")
            )
            await record(result)
            return result
        }

        // 先删同类 pending 请求，再用相同 identifier 添加。即使权限检查或 add
        // 失败，也不会留下一个旧请求和多个新请求叠加；系统本身也会按 identifier 覆盖。
        if removeExisting {
            center.removePending([identifier])
        }

        let status: NotificationAuthorizationStatus
        if let statusOverride {
            status = statusOverride
        } else {
            status = await checkAuthorization()
        }
        guard status.canSendNotifications else {
            let result = NotificationOperationResult.failure(authorizationFailure(for: status))
            await record(result)
            return result
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await center.add(request)
            let result = NotificationOperationResult.success(identifier: identifier)
            await record(result)
            return result
        } catch {
            let result = NotificationOperationResult.failure(mapNotificationError(error, fallback: .addFailed))
            await record(result)
            return result
        }
    }

    func removePendingNotification(identifier: String) {
        guard !identifier.isEmpty else { return }
        center.removePending([identifier])
    }

    func removePendingNotifications(identifiers: [String]) {
        let identifiers = identifiers.filter { !$0.isEmpty }
        guard !identifiers.isEmpty else { return }
        center.removePending(identifiers)
    }

    private func record(_ result: NotificationOperationResult) async {
        let message: String?
        switch result {
        case .success:
            message = nil
        case .skipped(let reason):
            message = reason
        case .failure(let failure):
            message = failure.message
        }

        await MainActor.run {
            self.lastResult = result
            self.lastErrorMessage = message
        }

        if case .failure(let failure) = result {
            print("[Notification] 通知操作失败：\(failure.message)")
        }
    }

    private func mapNotificationError(
        _ error: Error,
        fallback: NotificationFailureReason
    ) -> NotificationFailure {
        let nsError = error as NSError
        let searchable = [
            nsError.localizedDescription,
            nsError.domain,
            String(describing: error)
        ].joined(separator: " ").lowercased()

        if searchable.contains("too many")
            || searchable.contains("exceed")
            || searchable.contains("maximum")
            || searchable.contains("limit")
            || searchable.contains("过多")
            || searchable.contains("上限") {
            return NotificationFailure(reason: .tooManyNotifications)
        }

        if (nsError.domain == UNErrorDomain && nsError.code == 1)
            || searchable.contains("not allowed")
            || searchable.contains("denied")
            || searchable.contains("restricted")
            || searchable.contains("不允许")
            || searchable.contains("限制") {
            return NotificationFailure(reason: .systemRestricted)
        }

        return NotificationFailure(reason: fallback)
    }

    // MARK: - Daily study reminder

    @discardableResult
    func setDailyNotification(enabled: Bool, time: Date? = nil) async -> NotificationOperationResult {
        guard enabled else {
            cancelDailyNotification()
            await setDailyRuntimeState(false)
            if let persistenceFailure = await persistDailySetting(false) {
                let result = NotificationOperationResult.failure(persistenceFailure)
                await record(result)
                return result
            }
            let result = NotificationOperationResult.success(identifier: NotificationIdentifiers.dailyStudyReminder)
            await record(result)
            return result
        }

        let proposedTime = time ?? notificationTime
        let authorization = await requestAuthorization()
        guard case .success(let status) = authorization else {
            cancelDailyNotification()
            await setDailyRuntimeState(false)
            _ = await persistDailySetting(false)
            if case .failure(let failure) = authorization {
                return .failure(failure)
            }
            return .failure(NotificationFailure(reason: .authorizationRequired))
        }

        let result = await scheduleDailyNotification(at: proposedTime, authorizationStatus: status)
        guard result.isSuccess else {
            cancelDailyNotification()
            await setDailyRuntimeState(false)
            _ = await persistDailySetting(false)
            return result
        }

        await MainActor.run {
            self.notificationTime = proposedTime
        }
        if let persistenceFailure = await persistDailySetting(true) {
            cancelDailyNotification()
            await setDailyRuntimeState(false)
            let failureResult = NotificationOperationResult.failure(persistenceFailure)
            await record(failureResult)
            return failureResult
        }
        await setDailyRuntimeState(true)
        return result
    }

    @discardableResult
    func updateNotificationTime(_ time: Date) async -> NotificationOperationResult {
        let oldTime = notificationTime
        guard dailyNotificationEnabled else {
            await MainActor.run { self.notificationTime = time }
            let result = NotificationOperationResult.skipped(reason: "每日提醒未启用，未安排新请求。")
            await record(result)
            return result
        }

        let result = await scheduleDailyNotification(at: time, authorizationStatus: nil)
        guard result.isSuccess else {
            await MainActor.run { self.notificationTime = oldTime }
            cancelDailyNotification()
            await setDailyRuntimeState(false)
            _ = await persistDailySetting(false)
            return result
        }

        await MainActor.run { self.notificationTime = time }
        return result
    }

    private func scheduleDailyNotification(
        at date: Date,
        authorizationStatus statusOverride: NotificationAuthorizationStatus?
    ) async -> NotificationOperationResult {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let content = Self.makePrivateContent(
            title: "学习提醒",
            body: "今日学习提醒",
            userInfo: ["kind": "dailyStudyReminder"]
        )
        return await submitNotification(
            identifier: NotificationIdentifiers.dailyStudyReminder,
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: statusOverride
        )
    }

    func cancelDailyNotification() {
        removePendingNotification(identifier: NotificationIdentifiers.dailyStudyReminder)
    }

    private func setDailyRuntimeState(_ enabled: Bool) async {
        await MainActor.run {
            self.dailyNotificationEnabled = enabled
        }
    }

    private func persistDailySetting(_ enabled: Bool) async -> NotificationFailure? {
        let settings = storageService.loadSettings()
        settings.reminderEnabled = enabled
        guard storageService.saveSettings(settings) else {
            return NotificationFailure(reason: .settingsPersistenceFailed)
        }
        persistedReminderEnabled = enabled
        return nil
    }

    // MARK: - Study plan and review task reminders

    @discardableResult
    func sendStudyPlanNotification(plans: [ReviewPlan]) async -> NotificationOperationResult {
        let status = await checkAuthorization()
        guard status.canSendNotifications else {
            let result = NotificationOperationResult.failure(authorizationFailure(for: status))
            await record(result)
            return result
        }

        let today = Calendar.current.startOfDay(for: Date())
        let todayPlans = plans.filter { plan in
            plan.dailyPlans.contains { dailyPlan in
                Calendar.current.isDate(dailyPlan.date, inSameDayAs: today)
            }
        }
        let remainingTasks = todayPlans.flatMap(\.dailyPlans)
            .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
            .flatMap(\.tasks)
            .filter { !$0.isCompleted }
            .count

        guard remainingTasks > 0 else {
            let result = NotificationOperationResult.skipped(reason: "今天没有未完成的复习任务。")
            await record(result)
            return result
        }

        let content = Self.makePrivateContent(
            title: "学习进度",
            body: "今日学习进度已更新",
            userInfo: ["kind": "studyProgress"]
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        return await submitNotification(
            identifier: NotificationIdentifiers.studyProgress,
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: status
        )
    }

    @discardableResult
    func sendTaskReminderNotification(task: ReviewTask, plan: ReviewPlan) async -> NotificationOperationResult {
        _ = plan
        let status = await checkAuthorization()
        guard status.canSendNotifications else {
            let result = NotificationOperationResult.failure(authorizationFailure(for: status))
            await record(result)
            return result
        }

        let content = Self.makePrivateContent(
            title: "复习提醒",
            body: "有一项复习任务到点了",
            userInfo: [
                "kind": "reviewTask",
                "reviewTaskID": task.id.uuidString
            ]
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        return await submitNotification(
            identifier: NotificationIdentifiers.reviewTask(task.id),
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: status
        )
    }

    // MARK: - Todo reminders

    /// 现有 TodoService 是同步调用方，保留这个兼容入口；真正的 add 仍在异步
    /// 闭包中执行并记录明确结果。需要同步等待结果的调用方请使用下面的 async 方法。
    @discardableResult
    func scheduleTodoReminder(item: TodoItem, at date: Date) -> Task<NotificationOperationResult, Never> {
        Task { [weak self] in
            guard let self else {
                return .failure(NotificationFailure(
                    reason: .addFailed,
                    message: "通知服务已释放，待办提醒未安排。"
                ))
            }
            let result = await self.scheduleTodoReminderAsync(
                item: item,
                at: date,
                requestAuthorization: true
            )
            if case .failure(let failure) = result {
                print("[Notification] 待办提醒未启用：\(failure.message)")
            }
            return result
        }
    }

    /// 可等待真实 add 结果的待办提醒入口。`requestAuthorization: false` 用于
    /// 后台/启动恢复，只查询状态，不弹权限框。
    @discardableResult
    func scheduleTodoReminderAsync(
        item: TodoItem,
        at date: Date,
        requestAuthorization: Bool = true
    ) async -> NotificationOperationResult {
        guard date > Date() else {
            let result = NotificationOperationResult.failure(
                NotificationFailure(reason: .invalidRequest, message: "待办提醒时间必须晚于当前时间。")
            )
            await record(result)
            return result
        }

        // 同一待办的旧请求先移除；重复开关/恢复不会留下多个 pending。
        let identifier = NotificationIdentifiers.todo(item.id)
        removePendingNotification(identifier: identifier)

        let authorization: NotificationAuthorizationResult
        if requestAuthorization {
            authorization = await self.requestAuthorization()
        } else {
            let status = await checkAuthorization()
            authorization = status.canSendNotifications
                ? .success(status)
                : .failure(authorizationFailure(for: status))
        }

        guard case .success(let status) = authorization else {
            if case .failure(let failure) = authorization {
                let result = NotificationOperationResult.failure(failure)
                await record(result)
                return result
            }
            let result = NotificationOperationResult.failure(NotificationFailure(reason: .authorizationRequired))
            await record(result)
            return result
        }

        let content = Self.makePrivateContent(
            title: "待办提醒",
            body: "有一项待办到点了",
            userInfo: [
                "kind": "todo",
                "todoID": item.id.uuidString
            ]
        )
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return await submitNotification(
            identifier: identifier,
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: status
        )
    }

    func cancelTodoReminder(todoID: UUID) {
        removePendingNotification(identifier: NotificationIdentifiers.todo(todoID))
    }

    /// 立即提醒也使用中性正文；调用方传入的 title/body 可能是私密内容，故不透传。
    @discardableResult
    func sendImmediateTodoNotification(title _: String, body _: String) async -> NotificationOperationResult {
        let status = await checkAuthorization()
        guard status.canSendNotifications else {
            let result = NotificationOperationResult.failure(authorizationFailure(for: status))
            await record(result)
            return result
        }

        let content = Self.makePrivateContent(
            title: "待办提醒",
            body: "有一项待办提醒",
            userInfo: ["kind": "todoImmediate"]
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let identifier = "todoImmediate_\(UUID().uuidString)"
        return await submitNotification(
            identifier: identifier,
            content: content,
            trigger: trigger,
            removeExisting: false,
            authorizationStatus: status
        )
    }
}
