import Foundation
import AppKit
import UserNotifications

/// 通知点击路由。
///
/// 纪念日、待办、复习任务、习惯打卡、番茄钟的通知都带 `userInfo["kind"]`，
/// 但工程此前没有实现 `UNUserNotificationCenterDelegate`：
/// 点击通知只会把 App 唤到前台，不知道该跳到哪个页面。
/// 这里按 kind 分发到对应页面；需要打开独立窗口的（许愿）走状态桥。
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    private override init() { super.init() }

    /// 应用启动时注册。必须在 AppState 建立之后调用，否则无处切换页面。
    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// 前台收到通知时按 passive 呈现，避免静默丢失。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 点击通知：冷启动（App 未运行）时先记下，等主窗口就绪后再跳转。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let route = Route(userInfo: info) {
            pendingRoute = route
            if appStateReady { deliver(route) }
        }
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    // MARK: - 状态

    private var pendingRoute: Route?
    private var appState: AppState?
    private var appStateReady = false { didSet { if appStateReady { flushPending() } } }

    /// AppState 建立后调用。
    func attach(appState: AppState) {
        self.appState = appState
        appStateReady = true
    }

    private func flushPending() {
        guard let pendingRoute, let appState else { return }
        self.pendingRoute = nil
        deliver(pendingRoute, to: appState)
    }

    private func deliver(_ route: Route) {
        guard let appState else { return }
        deliver(route, to: appState)
    }

    private func deliver(_ route: Route, to appState: AppState) {
        switch route {
        case .wishWindow:
            SharedAppStateProxy.shared.requestWishWindow()
        case .setTab(let tab):
            appState.selectedTab = tab
        }
    }

    // MARK: - 路由定义

    /// 通知点击要触发的动作。
    enum Route: Equatable {
        /// 需要打开一个独立窗口
        case wishWindow
        /// 切换到某个侧栏页面（沿用现有 tab 编号，参见 docs/notes.md 第 17 章）
        case setTab(Int)

        init?(userInfo: [AnyHashable: Any]) {
            guard let kind = userInfo["kind"] as? String else { return nil }
            switch kind {
            // 目前只有许愿是独立窗口；其余按 tab 跳转。
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
