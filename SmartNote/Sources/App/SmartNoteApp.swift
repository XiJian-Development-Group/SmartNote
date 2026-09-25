import SwiftUI
import AppKit
import Combine

@main
struct SmartNoteApp: App {
    @StateObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _appState = StateObject(wrappedValue: AppState())
        // 使用无队列的观察者，确保 willTerminate 通知处理在退出前同步完成。
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            WhiteboardService.shared.flushPendingSave()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environment(\.appTheme, appState.theme)
                .appTint(appState.theme.tint)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(appState.colorScheme)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .background {
                        // 进入后台前同步落盘，避免 debounce 窗口内退出导致数据丢失。
                        WhiteboardService.shared.flushPendingSave()
                    }
                }
        }
        .windowStyle(.automatic)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入资料") {
                    appState.showFileImporter = true
                }
                .keyboardShortcut("i", modifiers: .command)
            }

            CommandMenu("复习") {
                Button("开始复习计划") {
                    appState.selectedTab = 2
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("提取考点") {
                    appState.selectedTab = 1
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        // 日记编辑器独立窗口
        // - openWindow(id: "diary-editor")            → 新建（无 value）
        // - openWindow(id: "diary-editor", value: id)  → 编辑对应日记
        WindowGroup("日记编辑器", id: "diary-editor", for: UUID.self) { $entryID in
            DiaryEditorView(entryID: entryID)
                .environmentObject(appState)
                .environment(\.appTheme, appState.theme)
                .appTint(appState.theme.tint)
                .frame(minWidth: 700, minHeight: 600)
                .preferredColorScheme(appState.colorScheme)
        }
        .windowResizability(.contentMinSize)

        // 许愿/还愿独立全屏窗口。动态星空需要完整画布，挤在侧边栏详情区会明显受限。
        // - openWindow(id: "wish-fullscreen") → 复用已有窗口，不重复创建
        Window("许愿 · 还愿", id: "wish-fullscreen") {
            WishView()
                .environmentObject(appState)
                .environment(\.appTheme, appState.theme)
                .appTint(appState.theme.tint)
                .preferredColorScheme(appState.colorScheme)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environment(\.appTheme, appState.theme)
                .appTint(appState.theme.tint)
                .preferredColorScheme(appState.colorScheme)
        }

        // 菜单栏 App（macOS 13+ 原生 MenuBarExtra）。首次启动带 toggle 控制；
        // 设置页可关闭。关闭时不显示菜单栏图标。
        MenuBarExtra("智学笔记", systemImage: "book.fill") {
            MenuBarContentView()
                .environmentObject(appState)
                .environment(\.appTheme, appState.theme)
                .appTint(appState.theme.tint)
                .preferredColorScheme(appState.colorScheme)
        }
        .menuBarExtraStyle(.menu)
    }
}

extension AppSettings.DarkModePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
