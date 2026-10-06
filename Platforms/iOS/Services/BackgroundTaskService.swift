import Foundation
import BackgroundTasks
import SwiftUI

@MainActor
class BackgroundTaskService: ObservableObject {
    static let shared = BackgroundTaskService()

    private let appRefreshIdentifier = "com.skyc8266.smartnote.ios.apprefresh"
    private let backgroundSyncIdentifier = "com.skyc8266.smartnote.ios.backgroundsync"
    private let processingIdentifier = "com.skyc8266.smartnote.ios.processing"

    private init() {}

    /// App 当前是否声明了后台执行模式。
    ///
    /// `BGTaskScheduler.register(forTaskWithIdentifier:using:launchHandler:)`
    /// 在标识符未出现在 `UIBackgroundModes` 时会**抛出
    /// `NSInternalInconsistencyException`**——也就是启动即崩溃，不是返回错误。
    ///
    /// 个人（免费）开发者账号拿不到带 `com.apple.developer.background-modes`
    /// 的描述文件，因此本工程默认不声明后台模式（见 project.yml）。
    /// 这里必须先探测再注册，否则每次冷启动都会崩。
    private var declaresBackgroundModes: Bool {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            return false
        }
        // 本工程用到的三个模式：fetch / processing / remote-notification
        let required: Set<String> = ["fetch", "processing", "remote-notification"]
        return required.isSubset(of: Set(modes))
    }

    /// 注册后台任务。Info.plist 未声明对应后台模式时**安全跳过**。
    ///
    /// - Returns: 是否真的注册了。`false` 表示当前签名/配置下后台任务不可用，
    ///   调用方据此不必再尝试 `scheduleXxx()`。
    @discardableResult
    func registerTasks() -> Bool {
        guard declaresBackgroundModes else {
            #if DEBUG
            print("[BackgroundTask] Info.plist 未声明 UIBackgroundModes，跳过后台任务注册。")
            #endif
            return false
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: appRefreshIdentifier, using: nil) { task in
            self.handleAppRefresh(task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncIdentifier, using: nil) { task in
            self.handleBackgroundSync(task as! BGAppRefreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            self.handleProcessing(task as! BGProcessingTask)
        }
        return true
    }

    // 请求后台刷新（约每 15-30 分钟一次）
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: appRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 分钟后
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("提交 App Refresh 任务失败：\(error)")
        }
    }

    // 请求后台同步（需要网络）
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundSyncIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60) // 30 分钟后
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("提交 Background Sync 任务失败：\(error)")
        }
    }

    // 请求后台处理（耗时任务，如备份、AI 分析等）
    func scheduleProcessing(requiresNetwork: Bool = true, requiresExternalPower: Bool = false) {
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresNetworkConnectivity = requiresNetwork
        request.requiresExternalPower = requiresExternalPower
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 小时后
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("提交 Processing 任务失败：\(error)")
        }
    }

    // 取消所有任务
    func cancelAllTasks() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }

    // MARK: - 任务处理

    private func handleAppRefresh(_ task: BGAppRefreshTask) {
        // 设置过期处理
        task.expirationHandler = {
            // 清理工作
        }

        // 执行轻量级刷新：检查更新、同步设置、清理缓存等
        Task {
            await performLightweightRefresh()
            task.setTaskCompleted(success: true)
            // 重新调度下一次
            self.scheduleAppRefresh()
        }
    }

    private func handleBackgroundSync(_ task: BGAppRefreshTask) {
        task.expirationHandler = {
            // 取消正在进行的同步
        }

        Task {
            await performBackgroundSync()
            task.setTaskCompleted(success: true)
            self.scheduleBackgroundSync()
        }
    }

    private func handleProcessing(_ task: BGProcessingTask) {
        task.expirationHandler = {
            // 取消耗时任务
        }

        Task {
            await performHeavyProcessing()
            task.setTaskCompleted(success: true)
        }
    }

    private func performLightweightRefresh() async {
        // 1. 检查应用更新
        // 2. 同步用户设置到 iCloud
        // 3. 清理临时文件
        // 4. 更新 Widget 时间线
        // 5. 更新 Live Activity
        print("执行轻量级后台刷新")
    }

    private func performBackgroundSync() async {
        // 1. 同步资料、计划、错题到 CloudKit
        // 2. 下载共享内容
        // 3. 更新 Spotlight 索引
        print("执行后台同步")
    }

    private func performHeavyProcessing() async {
        // 1. 完整备份到 iCloud Drive
        // 2. AI 批量分析（如果有待处理队列）
        // 3. OCR 批量处理
        // 4. 生成学习报告
        print("执行后台耗时处理")
    }

    // 从 AppDelegate 调用
    func handleBackgroundTasks() {
        // iOS 会在后台自动调用已注册的任务
    }
}

// AppDelegate 扩展
extension BackgroundTaskService {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // 处理后台下载/上传完成
        completionHandler()
    }
}