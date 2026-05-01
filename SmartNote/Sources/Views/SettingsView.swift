import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings = StorageService().loadSettings()
    
    var body: some View {
        TabView {
            generalSection
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
            
            llmSection
                .tabItem {
                    Label("AI 分析", systemImage: "brain")
                }
            
            storageSection
                .tabItem {
                    Label("存储", systemImage: "internaldrive")
                }
            
            aboutSection
                .tabItem {
                    Label("关于", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .onChange(of: settings) { newValue in
            appState.storageService.saveSettings(newValue)
        }
    }
    
    private var generalSection: some View {
        Form {
            Section("显示") {
                Picker("外观", selection: $settings.darkModePreference) {
                    Text("跟随系统").tag(AppSettings.DarkModePreference.system)
                    Text("浅色").tag(AppSettings.DarkModePreference.light)
                    Text("深色").tag(AppSettings.DarkModePreference.dark)
                }
                
                Toggle("显示文件扩展名", isOn: $settings.showFileExtensions)
            }
            
            Section("日历与提醒") {
                Toggle("启用日历同步", isOn: $settings.calendarIntegrationEnabled)
                Toggle("启用提醒事项", isOn: $settings.reminderEnabled)
                
                Stepper("默认学习时长: \(settings.defaultStudyMinutes) 分钟", 
                       value: $settings.defaultStudyMinutes,
                       in: 15...120,
                       step: 15)
            }
            
            Section("文件扫描") {
                Toggle("启动时自动扫描", isOn: $settings.autoScanDirectories)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    private var llmSection: some View {
        LLMSettingsView()
    }
    
    private var storageSection: some View {
        Form {
            Section("存储信息") {
                HStack {
                    Text("资料数量")
                    Spacer()
                    Text("\(appState.materials.count)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("复习计划")
                    Spacer()
                    Text("\(appState.reviewPlans.count)")
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("占用空间")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: StorageService().getStorageSize(), countStyle: .file))
                        .foregroundColor(.secondary)
                }
            }
            
            Section {
                Button("清除所有数据") {
                    clearAllData()
                }
                .foregroundColor(.red)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
    
    private var aboutSection: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "book.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text("智学笔记")
                .font(.title)
                .fontWeight(.bold)
            
            Text("版本 1.0.0")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("macOS 原生大学生智能复习工具")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Text("© 2024 SmartNote")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    private func clearAllData() {
        appState.materials.removeAll()
        appState.reviewPlans.removeAll()
        appState.storageService.clearAllData()
    }
}
