import SwiftUI
import UserNotifications

@main
struct SmartNoteApp_iOS: App {
    @StateObject private var appState = AppState_iOS()
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView_iOS()
                .environmentObject(appState)
                .environment(\.appTheme, appState.theme)
                .appTint(appState.theme.tint)
                .preferredColorScheme(appState.colorScheme)
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:
                        appState.applicationDidBecomeActive()
                    case .inactive:
                        appState.applicationWillResignActive()
                    case .background:
                        appState.applicationDidEnterBackground()
                    @unknown default:
                        break
                    }
                }
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    appState.handleHandoff(userActivity)
                }
        }
        .defaultSize(width: 1280, height: 800)
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 前台展示策略与通知点击路由都由 `PushNotificationService` 负责
        // （它实现了 `UNUserNotificationCenterDelegate`）。
        // `NotificationService_iOS` 只负责本地提醒的调度，不作为 delegate。
        UNUserNotificationCenter.current().delegate = PushNotificationService.shared
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Handoff / Universal Links 处理
    }
}