import SwiftUI

@main
struct SmartNoteApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 600)
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
        
        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
