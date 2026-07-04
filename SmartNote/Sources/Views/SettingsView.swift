import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var settings = StorageService().loadSettings()
    @State private var isCheckingUpdate: Bool = false
    @State private var updateMessage: String = ""
    
    var body: some View {
        TabView {
            generalSection
                .tabItem {
                    Label("通用", systemImage: "gear")
                }
            
            learningProfileSection
                .tabItem {
                    Label("学习", systemImage: "brain.head.profile")
                }
            
            llmSection
                .tabItem {
                    Label("AI 分析", systemImage: "brain")
                }
            
            storageSection
                .tabItem {
                    Label("存储", systemImage: "internaldrive")
                }
        }
        .frame(width: 500, height: 400)
        .onChange(of: settings) { _old, newValue in
            appState.storageService.saveSettings(newValue)
            // update update service repository and schedule when settings change
            appState.updateUpdateServiceRepositoryIfNeeded(owner: newValue.updateRepoOwner, repo: newValue.updateRepoName)
            appState.scheduleUpdateChecks(hoursInterval: newValue.updateCheckIntervalHours)
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
                
                Toggle("每日学习通知", isOn: Binding(
                    get: { appState.notificationService.dailyNotificationEnabled },
                    set: { newValue in
                        Task {
                            await appState.notificationService.setDailyNotification(enabled: newValue)
                        }
                    }
                ))
                
                if appState.notificationService.dailyNotificationEnabled {
                    DatePicker(
                        "通知时间",
                        selection: Binding(
                            get: { appState.notificationService.notificationTime },
                            set: { newValue in
                                Task {
                                    await appState.notificationService.updateNotificationTime(newValue)
                                }
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                }
                
                Stepper("默认学习时长: \(settings.defaultStudyMinutes) 分钟",
                       value: $settings.defaultStudyMinutes,
                       in: 15...120,
                       step: 15)
            }

            Section("更新") {
                Toggle("自动下载并安装更新", isOn: $settings.autoUpdateEnabled)
                    .onChange(of: settings.autoUpdateEnabled) { _old, newValue in
                        if newValue {
                            Task {
                                await appState.performAutoCheckIfEnabled()
                            }
                        }
                    }
                Stepper("检查间隔: \(settings.updateCheckIntervalHours) 小时", value: $settings.updateCheckIntervalHours, in: 1...168)
                HStack {
                    Text("Repo")
                    TextField("Owner", text: $settings.updateRepoOwner)
                    Text("/")
                    TextField("Repo", text: $settings.updateRepoName)
                }
                Picker("更新渠道", selection: $settings.updateChannel) {
                    Text("Latest").tag(AppSettings.UpdateChannel.latest)
                    Text("Pre-release").tag(AppSettings.UpdateChannel.prerelease)
                }
                HStack {
                    Button(action: {
                        Task {
                            isCheckingUpdate = true
                            updateMessage = "正在检查..."
                            do {
                                // save repo/settings changes before checking
                                appState.storageService.saveSettings(settings)
                                // apply repo change immediately
                                appState.updateUpdateServiceRepositoryIfNeeded(owner: settings.updateRepoOwner, repo: settings.updateRepoName)
                                appState.scheduleUpdateChecks(hoursInterval: settings.updateCheckIntervalHours)
                                let channel = settings.updateChannel
                                let svcChannel: UpdateService.Channel = (channel == .prerelease) ? .prerelease : .latest
                                // ensure updateService is configured with latest owner/repo
                                // (AppState created UpdateService at init; for repo changes user must restart to apply to service instance)
                                if let release = try await appState.updateService.checkForUpdate(channel: svcChannel) {
                                    updateMessage = "找到更新: \(release.name ?? release.tag_name ?? "无名")"
                                    // send notification to user that an update is available
                                    Task {
                                        await appState.updateService.notifyUserUpdateFound(release)
                                    }
                                    // persist last check
                                    var s = appState.storageService.loadSettings()
                                    s.lastUpdateCheckDate = Date()
                                    s.lastFoundReleaseName = release.name ?? release.tag_name
                                    appState.storageService.saveSettings(s)
                                } else {
                                    updateMessage = "未找到符合条件的更新"
                                    var s = appState.storageService.loadSettings()
                                    s.lastUpdateCheckDate = Date()
                                    appState.storageService.saveSettings(s)
                                }
                            } catch {
                                updateMessage = "检查失败: \(error.localizedDescription)"
                            }
                            isCheckingUpdate = false
                        }
                    }) {
                        if isCheckingUpdate {
                            ProgressView()
                        } else {
                            Text("检查更新")
                        }
                    }
                    // show progress and logs (with auto-scroll and copy/clear controls)
                    VStack(alignment: .leading) {
                        if let p = appState.updateService.downloadProgress, appState.updateService.isDownloading {
                            ProgressView(value: p) {
                                Text("下载中：\(Int((p * 100).rounded()))%")
                            }
                            .progressViewStyle(.linear)
                        } else if appState.updateService.isDownloading {
                            ProgressView()
                        }

                        if !appState.updateService.logs.isEmpty {
                            HStack(spacing: 8) {
                                Text("更新日志:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button(action: {
                                    // copy logs to clipboard
                                    let joined = appState.updateService.logs.joined(separator: "\n")
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(joined, forType: .string)
                                }) {
                                    Image(systemName: "doc.on.clipboard")
                                }
                                .buttonStyle(.bordered)

                                Button(action: {
                                    // clear logs on main actor
                                    Task { @MainActor in
                                        appState.updateService.logs.removeAll()
                                    }
                                }) {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                            }

                            ScrollViewReader { proxy in
                                ScrollView(.vertical) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(appState.updateService.logs.enumerated()), id: \.0) { idx, line in
                                            HStack(alignment: .top, spacing: 8) {
                                                Text("\(idx + 1)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .frame(width: 28, alignment: .trailing)
                                                Text(line)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .id(idx)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .frame(maxHeight: 140)
                                .onChange(of: appState.updateService.logs.count) { _ in
                                    // scroll to bottom when logs change
                                    if let last = appState.updateService.logs.indices.last {
                                        withAnimation(.easeOut) {
                                            proxy.scrollTo(last, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.top, 6)

                    // Install & Relaunch button when an installed app is available
                    if let installed = appState.updateService.lastInstalledURL {
                        HStack {
                            Button("安装并重启") {
                                Task {
                                    do {
                                        try appState.updateService.installAndRelaunchApp(at: installed)
                                    } catch {
                                        updateMessage = "安装并重启失败: \(error.localizedDescription)"
                                    }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    // Download & Install button
                    if let found = appState.updateService.latestCheckedRelease {
                        Button("下载并安装") {
                            Task {
                                updateMessage = "开始下载..."
                                do {
                                    let installed = try await appState.updateService.performDownloadAndInstall(release: found, autoInstall: settings.autoUpdateEnabled)
                                    if let url = installed {
                                        updateMessage = "已下载/安装: \(url.path)"
                                    } else {
                                        updateMessage = "下载完成，未找到可安装的 .app"
                                    }
                                    var s = appState.storageService.loadSettings()
                                    s.lastUpdateCheckDate = Date()
                                    s.lastFoundReleaseName = found.name ?? found.tag_name
                                    appState.storageService.saveSettings(s)
                                } catch {
                                    updateMessage = "下载或安装失败: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                    Spacer()
                    Text(updateMessage)
                        .foregroundColor(.secondary)
                }
                if settings.autoUpdateEnabled {
                    HStack {
                        Text("下次计划检查:")
                        Spacer()
                        let last = appState.storageService.loadSettings().lastUpdateCheckDate ?? Date()
                        let next = Calendar.current.date(byAdding: .hour, value: settings.updateCheckIntervalHours, to: last) ?? Date()
                        Text(next, style: .date)
                            .foregroundColor(.secondary)
                    }
                }
                if let last = appState.storageService.loadSettings().lastUpdateCheckDate {
                    HStack {
                        Text("上次检查:")
                        Spacer()
                        Text(last, style: .date)
                            .foregroundColor(.secondary)
                    }
                }
                if let name = appState.storageService.loadSettings().lastFoundReleaseName {
                    HStack {
                        Text("上次发现:")
                        Spacer()
                        Text(name)
                            .foregroundColor(.secondary)
                    }
                }
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
    
    private var learningProfileSection: some View {
        LearningProfileSettingsView()
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
            
            Text("版本 1.3.0")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("AI智能复习工具")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Text("By skyc8266")
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
