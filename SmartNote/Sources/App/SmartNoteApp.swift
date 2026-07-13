import SwiftUI

@main
struct SmartNoteApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(appState.colorScheme)
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
                .frame(minWidth: 700, minHeight: 600)
                .preferredColorScheme(appState.colorScheme)
        }
        .windowResizability(.contentMinSize)
        
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
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
