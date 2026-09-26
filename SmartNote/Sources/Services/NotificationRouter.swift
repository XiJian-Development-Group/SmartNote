import Foundation
import AppKit
import UserNotifications

/// 通知点击路由。
///
/// 纪念日、待办、复习任务、习惯打卡、番茄钟的通知都带 `userInfo["kind"]`，
/// 但工程此前没有实现 `UNUserNotificationCenterDelegate`：
/// 点击通知只会把 App 唤到前台，不知道该跳到哪个页面。
/// 这里按 kind 分发到对应页面；需要打开独立窗口的（许愿）走状态桥。
///
/// 并发隔离：`UNUserNotificationCenterDelegate` 的方法不保证在主线程调用，
/// 若整个类标 `@MainActor` 会在 Swift 6 下产生 conformance 跨隔离警告。
/// 因此这里用 `nonisolated` 实现协议方法，只在里面做纯计算，
/// 需要触碰 AppState 时再显式切到 MainActor。
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    private override init() { super.init() }

    /// 应用启动时注册。必须在 AppState 建立之后调用，否则无处切换页面。
    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 把 AppState 交给路由器。此后通知点击才能切换页面。
    @MainActor
    func attach(appState: AppState) {
        self.appState = appState
        appStateReady = true
        flushPendingRouteIfNeeded()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 前台收到通知时照常弹出横幅与声音，避免静默丢失。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知。冷启动（App 未运行）时先记下路由，等 AppState 就绪后再投递。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = Route(userInfo: response.notification.request.content.userInfo)
        if let route {
            Task { @MainActor [weak self] in
                self?.enqueue(route)
            }
        }
        // 唤起应用由系统在点击时自动完成，这里只确保窗口在前台。
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
        completionHandler()
    }

    // MARK: - 状态（仅主线程访问）

    @MainActor private var pendingRoute: Route?
    @MainActor private weak var appState: AppState?
    @MainActor private var appStateReady = false

    @MainActor
    private func enqueue(_ route: Route) {
        pendingRoute = route
        flushPendingRouteIfNeeded()
    }

    /// AppState 尚未就绪时先挂起，就绪后立刻补投。
    @MainActor
    private func flushPendingRouteIfNeeded() {
        guard appStateReady, let route = pendingRoute, let appState else { return }
        pendingRoute = nil
        switch route {
        case .wishWindow:
            SharedAppStateProxy.shared.requestWishWindow()
        case .setTab(let tab):
            appState.selectedTab = tab
        }
    }

    // MARK: - 路由定义

    /// 通知点击要触发的动作。纯值类型，可在任意线程构造。
    enum Route: Equatable {
        /// 需要打开一个独立窗口
        case wishWindow
        /// 切换到某个侧栏页面（沿用现有 tab 编号，参见 docs/notes.md 第 17 章）
        case setTab(Int)

        init?(userInfo: [AnyHashable: Any]) {
            guard let kind = userInfo["kind"] as? String else { return nil }
            switch kind {
            case "anniversary": self = .setTab(25)
            case "todo", "todoImmediate": self = .setTab(20)
            case "reviewTask": self = .setTab(6)
            case "habit": self = .setTab(21)
            case "pomodoro": self = .setTab(10)
            case "dailyStudyReminder", "studyProgress": self = .setTab(7)
            case "wish": self = .wishWindow
            default: return nil
            }
        }
    }
}
