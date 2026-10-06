import Foundation
import ServiceManagement

/// 开机自启控制器（macOS 13+ 原生 SMAppService API）。
///
/// - 实现走系统注册方案 `SMAppService.mainApp`，不引第三方依赖。
/// - 该 API 等价于"系统设置 → 通用 → 登录项 → 打开 App 时允许后台启动"。
/// - 第一次 register 时系统会弹窗让用户批准；本服务仅触发注册，不绕过。
@MainActor
final class LaunchAtLoginService: ObservableObject {

    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published var enabledByUser: Bool = false
    @Published private(set) var lastError: String?

    init() {
        refreshStatus()
    }

    /// 重新读取系统状态
    func refreshStatus() {
        status = SMAppService.mainApp.status
        // 反映在 toggle 上
        switch status {
        case .enabled:
            enabledByUser = true
            lastError = nil
        case .requiresApproval:
            // 用户没在系统设置批准；toggle 显示为关
            enabledByUser = false
            lastError = "需要去「系统设置 → 通用 → 登录项」批准智学笔记后台启动"
        case .notRegistered, .notFound:
            enabledByUser = false
            lastError = nil
        @unknown default:
            enabledByUser = false
        }
    }

    /// 用户切换 toggle 时调用；内部决定 register / unregister
    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
            // 失败时把 toggle 弹回原值
            enabledByUser = SMAppService.mainApp.status == .enabled
        }
    }
}
