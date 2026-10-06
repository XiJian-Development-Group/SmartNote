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
    /// 移除全部已挂起请求。
    let cancelAllPending: () -> Void

    init(
        authorizationStatus: @escaping () async -> NotificationAuthorizationStatus,
        requestAuthorization: @escaping () async throws -> Bool,
        add: @escaping (UNNotificationRequest) async throws -> Void,
        removePending: @escaping ([String]) -> Void,
        pendingIdentifiers: @escaping () async -> Set<String> = { [] },
        cancelAllPending: @escaping () -> Void = {}
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.add = add
        self.removePending = removePending
        self.pendingIdentifiers = pendingIdentifiers
        self.cancelAllPending = cancelAllPending
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
            },
            cancelAllPending: {
                center.removeAllPendingNotificationRequests()
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
