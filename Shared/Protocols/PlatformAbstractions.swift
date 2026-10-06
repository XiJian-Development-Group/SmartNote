import Foundation
import UserNotifications
import UniformTypeIdentifiers

// MARK: - 平台无关的钥匙串协议

/// 密钥/密码存储。
///
/// Shared 层的 `StorageService` 与 `DiaryEncryptionService` 都需要把 API key、
/// 文件加密密码写入系统钥匙串，且**绝不允许**把这些凭据降级写进 JSON。
/// 但 macOS 用 `SecKeychain`（可指定非默认 keychain、iOS 上不存在），
/// iOS 用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 的条目属性，
/// 两者语义不完全一致，因此抽象成协议，由各平台提供实现。
protocol KeychainStoring: AnyObject {
    /// 保存或覆盖一个 UTF-8 字符串条目。失败抛出错误，不静默降级。
    @discardableResult
    func setString(_ value: String, for account: String) throws -> Bool

    /// 读取字符串条目。`nil` 表示条目不存在；其它错误抛出。
    func readString(for account: String) throws -> String?

    /// 删除字符串条目。不存在视为成功。
    @discardableResult
    func deleteString(for account: String) -> Bool

    /// 列出当前作用域内所有已存条目的 account。
    func listAccounts() -> [String]

    /// 删除当前作用域内所有条目。
    func deleteAll()
}

extension KeychainStoring {
    /// 便捷别名，供偏好 `set`/`read` 语义的调用方使用。
    @discardableResult
    func set(_ value: String, for account: String) throws -> Bool {
        try setString(value, for: account)
    }

    func read(for account: String) throws -> String? {
        try readString(for: account)
    }

    @discardableResult
    func delete(for account: String) -> Bool {
        deleteString(for: account)
    }

    /// 兼容现有 DiaryEncryptionService 调用
    func savePassword(_ password: String, for account: String) throws {
        try setString(password, for: account)
    }

    func loadPassword(for account: String) -> String? {
        (try? readString(for: account)) ?? nil
    }

    @discardableResult
    func deletePassword(for account: String) -> Bool {
        deleteString(for: account)
    }
}

// MARK: - 平台无关的存储协议

protocol AppStorageProvider {
    var appSupportDirectory: URL { get }
    func createDirectoryIfNeeded(_ url: URL) throws
    func fileExists(at url: URL) -> Bool
    func readData(from url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL) throws
    func deleteFile(at url: URL) throws
    func listFiles(in directory: URL) throws -> [URL]
}

// MARK: - 平台无关的图片协议

protocol PlatformImage: Sendable {
    var size: CGSize { get }
    func pngData() -> Data?
    func jpegData(compressionQuality: CGFloat) -> Data?
}

protocol ImageProvider {
    func loadImage(named: String) -> PlatformImage?
    func saveImage(_ image: PlatformImage, named: String) -> URL?
    func deleteImage(named: String)
    func listImages() -> [String]
}

// MARK: - 平台无关的语音合成协议

protocol SpeechSynthesizer {
    func speak(_ text: String, language: String?)
    func stop()
    func pause()
    func continueSpeaking()
    var isSpeaking: Bool { get }
}

// MARK: - 平台无关的文件选择协议

protocol FilePickerService {
    func pickFiles(types: [UTType], allowsMultiple: Bool) async -> [URL]
    func pickFolder() async -> URL?
}

// 注：这里没有“相机/扫描”协议。iOS 用 `VisionKit` 的
// `VNDocumentCameraViewController` 做文档扫描，macOS 用文件选择器导入，
// 两者的 UI 流程和返回类型都不同，没有可以共享的抽象。
// Shared 层需要图像时统一走下面的 `TextRecognizing`。

// MARK: - 平台无关的文字识别协议

/// 图像文字识别。macOS / iOS 各自用 Vision 实现，LLMService 只依赖这个协议，
/// 这样 Shared 里的 LLMService 不需要 import AppKit 或 UIKit。
///
/// - Note: 统一用 `Data` 而不是 NSImage / UIImage：位图跨平台表示只有 Data，
///   具体的解码与预处理交给各平台实现内部的 Vision 管线。
protocol TextRecognizing: AnyObject {
    /// 从图片文件识别文字。
    func recognizeText(from imageURL: URL) async -> String?
    /// 从内存中的图片数据识别文字。
    func recognizeText(fromImageData data: Data) async -> String?
}

/// 平台文字识别实现的当前实例。
///
/// `OCRService`（macOS）与 `OCRService_iOS` 分属两个 target，Shared 无法引用。
/// 与 `PlatformNotificationService` 同样的做法：各平台的 `AppState` 在启动时
/// `register(_:)` 一次，Shared 的惰性单例只通过这里获取。
enum PlatformTextRecognizer {
    private nonisolated(unsafe) static var current: TextRecognizing?

    /// 注册当前平台的实现。由各平台 `AppState` 在启动时调用。
    nonisolated static func register(_ recognizer: TextRecognizing) {
        current = recognizer
    }

    /// 当前平台的实现；未注册时返回空实现。
    ///
    /// 返回空实现而不是崩溃，是因为惰性单例（`LearningAnalysisService.shared`）
    /// 可能在 `AppState` 注册之前就构造好。空实现只会让图像识别拿不到文字，
    /// 不会让整个 App 启动失败——真正的 OCR 路径会在注册后自动可用。
    nonisolated static func shared() -> TextRecognizing {
        current ?? UnavailableTextRecognizer()
    }
}

/// 未注册时的占位实现：始终返回 nil。
private final class UnavailableTextRecognizer: TextRecognizing {
    func recognizeText(from imageURL: URL) async -> String? { nil }
    func recognizeText(fromImageData data: Data) async -> String? { nil }
}

// MARK: - 平台无关的通知协议

/// Shared 层的仓库服务（待办、习惯、纪念日、复习、番茄钟）共用的通知能力。
///
/// 这些服务必须能查询/申请授权、按 `UNNotificationTrigger` 提交带明确标识符的
/// 请求、撤销已挂起的请求，并收到结构化的成功/跳过/失败结果——这些正是
/// `NotificationOperationResult` 存在的原因。协议因此照搬完整语义，
/// 而不是退化成 `scheduleLocalNotification` 这类更窄的接口，
/// 否则仓库层就要在两套行为之间做适配，反而更容易出现平台差异。
@MainActor
protocol NotificationServiceProtocol: AnyObject {
    /// 查询当前授权状态。**绝不**触发权限弹框。
    func checkAuthorization() async -> NotificationAuthorizationStatus

    /// 申请通知权限。只有用户主动触发时才调用。
    func requestAuthorization() async -> NotificationAuthorizationResult

    /// 提交一个通知请求。
    ///
    /// - Parameters:
    ///   - trigger: 为 nil 时立即投递一次。
    ///   - removeExisting: 为 true 时先移除同标识符的旧请求，避免通知中心堆叠。
    ///   - statusOverride: 调用方已查到的授权状态；为不可发送时直接返回
    ///     `.skipped`，不再触碰系统 API。为 nil 时实现方只查询、不请求权限。
    func submitNotification(
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger?,
        removeExisting: Bool,
        authorizationStatus statusOverride: NotificationAuthorizationStatus?
    ) async -> NotificationOperationResult

    /// 移除单个已挂起的请求。
    func removePendingNotification(identifier: String)

    /// 批量移除已挂起的请求。
    func removePendingNotifications(identifiers: [String])

    /// 设置/取消每日学习提醒。
    func setDailyNotification(enabled: Bool, time: Date?) async -> NotificationOperationResult

    /// 更新每日学习提醒的时间。
    func updateNotificationTime(_ time: Date) async -> NotificationOperationResult

    /// 移除全部已挂起的请求。
    func cancelAllNotifications()

    /// 待办提醒（供 `TodoService` 使用）。
    ///
    /// - Parameter requestAuthorization: 为 false 时只查询状态、绝不弹权限框，
    ///   用于“已有提醒的恢复/改期”这类后台路径。
    func scheduleTodoReminderAsync(
        item: TodoItem,
        at date: Date,
        requestAuthorization: Bool
    ) async -> NotificationOperationResult

    /// 撤销待办提醒（供 `TodoService` 使用）。
    func cancelTodoReminder(todoID: UUID)

    /// 构造不含敏感正文的通知内容。
    ///
    /// 声明为 `nonisolated`：它只构造 `UNMutableNotificationContent`，
    /// 不触碰任何 UI 或可观察状态，因此在非主线程的共享代码里也能安全调用。
    nonisolated static func makePrivateContent(
        title: String,
        body: String,
        userInfo: [String: Any]
    ) -> UNMutableNotificationContent
}

extension NotificationServiceProtocol {
    /// `submitNotification` 的便捷重载：覆盖同标识符旧请求（默认行为）。
    func submitNotification(
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger?
    ) async -> NotificationOperationResult {
        await submitNotification(
            identifier: identifier,
            content: content,
            trigger: trigger,
            removeExisting: true,
            authorizationStatus: nil
        )
    }

    /// `submitNotification` 的便捷重载：立即投递一次，不覆盖旧请求。
    func submitImmediateNotification(
        identifier: String,
        content: UNNotificationContent
    ) async -> NotificationOperationResult {
        await submitNotification(
            identifier: identifier,
            content: content,
            trigger: nil,
            removeExisting: false,
            authorizationStatus: nil
        )
    }
}

/// 平台通知实现的当前实例。
///
/// Shared 层的仓库服务需要一个默认实现（例如 `TodoService` 直接撤销待办提醒），
/// 但 `NotificationService` / `NotificationService_iOS` 分属两个平台 target，
/// Shared 无法引用任何一方。与 `StorageService.defaultKeychainService` 同样的做法：
/// 由各平台的 `AppState` 在启动时注册一次，Shared 只通过这里访问。
enum PlatformNotificationService {
    private nonisolated(unsafe) static var current: NotificationServiceProtocol?

    /// 未注册时返回的转发代理。见 `shared()` 的说明。
    ///
    /// 该代理满足 `@MainActor` 协议，其方法自动获得主线程隔离；但它的初始化
    /// 本身不碰主线程状态，因此可以在默认参数表达式等非隔离上下文中创建。
    private nonisolated(unsafe) static let deferred = DeferredNotificationService()

    /// 注册当前平台的实现。应用启动时由 `AppState` 调用一次。
    ///
    /// 标注为 `nonisolated`：它只是保存一个引用，必须能在默认参数表达式这种
    /// 非隔离上下文里被读取，因此不绑定到主线程。
    nonisolated static func register(_ service: NotificationServiceProtocol) {
        current = service
    }

    /// 已注册的真实实现。仅供 `DeferredNotificationService` 内部解析使用。
    nonisolated static func resolvedImplementation() -> NotificationServiceProtocol? {
        current
    }

    /// 当前平台的实现。
    ///
    /// 一些 Shared 单例（`PomodoroTimer.shared` 等）是惰性静态属性，
    /// 理论上可能在 `AppState` 注册之前就完成初始化。因此这里**不**在未注册时
    /// 直接崩溃，而是返回一个转发代理：它在每次调用时才解析真实实现。
    /// 注册发生后 `shared()` 直接返回真实实现，转发代理随之不再被使用。
    nonisolated static func shared() -> NotificationServiceProtocol {
        current ?? deferred
    }

    /// 构造不含私密内容的通知内容。
    ///
    /// 实现由已注册的平台服务提供，Shared 不复制一份，避免两边行为漂移。
        nonisolated static func makePrivateContent(
        title: String,
        body: String,
        userInfo: [String: Any] = [:]
    ) -> UNMutableNotificationContent {
        let service = shared()
        return type(of: service).makePrivateContent(title: title, body: body, userInfo: userInfo)
    }
}

/// 注册完成前使用的转发代理。
///
/// 每次调用都重新解析 `PlatformNotificationService.shared()`，
/// 因此调用方即使在注册前就持有它，也会在首次真正使用时拿到正确实现。
private final class DeferredNotificationService: NotificationServiceProtocol {
    // 协议是 `@MainActor`，但本代理只做转发；显式提供一个非隔离初始化，
    // 使它可以在默认参数表达式等同步非隔离上下文中创建。
    nonisolated init() {}
    /// 解析真实实现。注册尚未发生时说明 App 还没完成启动，
    /// 这属于编程错误，用断言把它暴露出来而不是静默吞掉。
    private func target() -> NotificationServiceProtocol {
        guard let current = PlatformNotificationService.resolvedImplementation() else {
            preconditionFailure(
                "PlatformNotificationService 尚未注册：请在 AppState 启动时调用 register(_:)。"
            )
        }
        return current
    }

    func checkAuthorization() async -> NotificationAuthorizationStatus {
        await target().checkAuthorization()
    }

    func requestAuthorization() async -> NotificationAuthorizationResult {
        await target().requestAuthorization()
    }

    func submitNotification(
        identifier: String,
        content: UNNotificationContent,
        trigger: UNNotificationTrigger?,
        removeExisting: Bool,
        authorizationStatus statusOverride: NotificationAuthorizationStatus?
    ) async -> NotificationOperationResult {
        await target().submitNotification(
            identifier: identifier,
            content: content,
            trigger: trigger,
            removeExisting: removeExisting,
            authorizationStatus: statusOverride
        )
    }

    func removePendingNotification(identifier: String) {
        target().removePendingNotification(identifier: identifier)
    }

    func removePendingNotifications(identifiers: [String]) {
        target().removePendingNotifications(identifiers: identifiers)
    }

    func setDailyNotification(enabled: Bool, time: Date?) async -> NotificationOperationResult {
        await target().setDailyNotification(enabled: enabled, time: time)
    }

    func updateNotificationTime(_ time: Date) async -> NotificationOperationResult {
        await target().updateNotificationTime(time)
    }

    func cancelAllNotifications() {
        target().cancelAllNotifications()
    }

    func scheduleTodoReminderAsync(
        item: TodoItem,
        at date: Date,
        requestAuthorization: Bool
    ) async -> NotificationOperationResult {
        await target().scheduleTodoReminderAsync(
            item: item,
            at: date,
            requestAuthorization: requestAuthorization
        )
    }

    func cancelTodoReminder(todoID: UUID) {
        target().cancelTodoReminder(todoID: todoID)
    }

    /// 未注册时无法构造通知内容（拿不到平台的静默/抢占策略），
    /// 因此退回到与两个平台实现一致的中性内容。
    nonisolated static func makePrivateContent(
        title: String,
        body: String,
        userInfo: [String: Any]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        content.userInfo = userInfo
        content.interruptionLevel = .passive
        return content
    }
}

// MARK: - 平台无关的触觉反馈协议

protocol HapticFeedbackServiceProtocol {
    func selection()
    func light()
    func medium()
    func heavy()
    func success()
    func warning()
    func error()
}

// MARK: - 平台无关的粘贴板协议

protocol PasteboardService {
    func copy(_ string: String)
    func copy(_ image: PlatformImage)
    func pasteString() -> String?
}

// MARK: - 平台无关的应用生命周期协议

protocol AppLifecycleService {
    var isActive: Bool { get }
    func applicationDidBecomeActive()
    func applicationWillResignActive()
    func applicationDidEnterBackground()
    func applicationWillTerminate()
}