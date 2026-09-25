import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var selectedTab: Int = 0
    @Published var showFileImporter: Bool = false
    @Published var isScanning: Bool = false
    @Published var isProcessingOCR: Bool = false
    @Published var isExtractingKeywords: Bool = false
    @Published var isAnalyzingWithAI: Bool = false
    @Published var materials: [StudyMaterial] = []
    @Published var selectedMaterial: StudyMaterial?
    @Published var extractedKeywords: [String] = []
    @Published var aiAnalysisResult: String = ""
    @Published var reviewPlans: [ReviewPlan] = []
    // 考试倒计时只以 AppState 为真相源，持久化在 examCountdowns.json；
    // 同步到 appSettings 仅用于兼容旧的只读调用，不再写回 settings.json。
    @Published var examCountdowns: [ExamCountdown] = [] {
        didSet {
            appSettings.examCountdowns = examCountdowns
            guard !isRestoringExamCountdowns else { return }
            storageService.saveExamCountdowns(examCountdowns)
        }
    }
    @Published var searchText: String = ""
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var appSettings: AppSettings = AppSettings() {
        didSet {
            // 防止设置页或其他调用方用旧快照替换整个 appSettings。
            if appSettings.examCountdowns != examCountdowns {
                appSettings.examCountdowns = examCountdowns
            }
        }
    }
    /// AppSettings 是嵌套 ObservableObject；单独发布外观状态，确保主题/明暗切换立即刷新所有 Scene。
    @Published private(set) var activeThemeID: AppSettings.ThemeID = .classic
    @Published private(set) var activeDarkModePreference: AppSettings.DarkModePreference = .system
    
    var colorScheme: ColorScheme? {
        // 节庆主题自带对比度方案；经典主题继续尊重“外观”中的明暗选择。
        activeThemeID == .classic
            ? activeDarkModePreference.colorScheme
            : theme.colorScheme
    }

    var theme: AppTheme {
        AppTheme.theme(for: activeThemeID)
    }

    var llmConfiguration: LLMConfiguration {
        get { appSettings.llmConfiguration }
        set {
            appSettings.llmConfiguration = newValue
            storageService.saveSettings(appSettings)
            llmService.updateConfiguration(newValue)
        }
    }
    
    let fileScanner = FileScannerService()
    let ocrService = OCRService()
    let keywordService = KeywordExtractionService()
    let calendarService = CalendarService()
    let storageService = StorageService()
    let backupService: BackupService
    let fileCryptoService = FileCryptoService()
    let keychainService = KeychainService()
    let launchAtLoginService = LaunchAtLoginService()
    let ambientSoundService = AmbientSoundService()
    let wishService = WishService()
    let anniversaryService = AnniversaryService()
    let calculatorEngine = CalculatorEngine()
    let speechService = SpeechService.shared
    let learningAnalysisService = LearningAnalysisService.shared
    let notificationService = NotificationService.shared
    let updateService: UpdateService
    let blessingService: BlessingService
    let historyService: HistoryService
    var updateCheckCancellable: AnyCancellable? = nil
    var llmService: LLMService
    private var hasLoadedExamCountdowns: Bool = false
    /// 从磁盘恢复倒计时期间抑制 didSet 写盘（避免用空值覆盖真实数据）。
    private var isRestoringExamCountdowns: Bool = false
    private var storageClearObserver: NSObjectProtocol?

    /// 最近一次启动期 schema 迁移结果（用于「备份与恢复」面板显示）
    @Published var lastStartupMigration: StartupMigrationResult?

    init() {
        let probeStorage = StorageService()
        // 1. 启动期自动迁移：先备份再升级字段。同步执行——zip 整个 App Support 一般 < 100MB、几秒内。
        let migrationResult = probeStorage.runStartupMigration()
        // 2. 重新读一次以拿到被迁移后的最新 settings
        let settings = probeStorage.loadSettings()

        self.backupService = BackupService(sourceRoot: probeStorage.appSupportURL)
        let config = settings.llmConfiguration
        self.llmService = LLMService(configuration: config)
        // initialize update service with configured repo
        self.updateService = UpdateService(owner: settings.updateRepoOwner, repo: settings.updateRepoName)
        self.blessingService = BlessingService()
        self.historyService = HistoryService(storageService: probeStorage)
        self.appSettings = settings
        self.activeThemeID = settings.themeID
        self.activeDarkModePreference = settings.darkModePreference
        self.lastStartupMigration = migrationResult
        loadSavedData()

        // 启动扫描走 FileScannerService 的异步路径，避免阻塞主线程。
        if settings.autoScanDirectories && !settings.scanPaths.isEmpty {
            let startupScanPaths = settings.scanPaths
            Task { [weak self] in
                await self?.performStartupScanIfNeeded(paths: startupScanPaths)
            }
        }

        // 「清除所有数据」后磁盘已空：重载内存状态，避免界面仍显示旧数据
        storageClearObserver = NotificationCenter.default.addObserver(
            forName: .storageDidClearAllData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.loadSavedData()
        }
        // 把自己桥给 Siri / Shortcuts intent 用
        MainActor.assumeIsolated {
            SharedAppStateProxy.shared.bind(self)
        }

        // perform initial auto-check if enabled
        if settings.autoUpdateEnabled {
            Task {
                await performAutoCheckIfEnabled()
            }
        }

        // schedule automatic checks according to saved interval
        scheduleUpdateChecks(hoursInterval: settings.updateCheckIntervalHours)
    }
    
    func refreshSettings() {
        let currentExamCountdowns = examCountdowns
        let loadedSettings = storageService.loadSettings()
        self.appSettings = loadedSettings
        self.activeThemeID = loadedSettings.themeID
        self.activeDarkModePreference = loadedSettings.darkModePreference
        // appSettings 的倒计时字段只作为内存镜像，不从旧磁盘快照反向覆盖。
        self.appSettings.examCountdowns = currentExamCountdowns
    }

    func setTheme(_ themeID: AppSettings.ThemeID) {
        guard activeThemeID != themeID else { return }
        appSettings.themeID = themeID
        activeThemeID = themeID
        storageService.saveSettings(appSettings)
    }

    func setDarkModePreference(_ preference: AppSettings.DarkModePreference) {
        guard activeDarkModePreference != preference else { return }
        appSettings.darkModePreference = preference
        activeDarkModePreference = preference
        storageService.saveSettings(appSettings)
    }

    func updateUpdateServiceRepositoryIfNeeded(owner: String, repo: String) {
        // update the service repository so manual checks use latest values
        updateService.updateRepository(owner: owner, repo: repo)
    }

    func scheduleUpdateChecks(hoursInterval: Int) {
        updateCheckCancellable?.cancel()
        let interval = max(1, hoursInterval)
        updateCheckCancellable = Timer.publish(every: TimeInterval(interval * 3600), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task {
                    await self?.performAutoCheckIfEnabled()
                }
            }
    }

    func performAutoCheckIfEnabled() async {
        // 这里只读取检查所需的配置快照，不在网络请求返回后复用它写盘。
        let settings = storageService.loadSettings()
        guard settings.autoUpdateEnabled else { return }
        let channel: UpdateService.Channel = (settings.updateChannel == .prerelease) ? .prerelease : .latest
        do {
            if let release = try await updateService.checkForUpdate(channel: channel) {
                // 请求期间用户可能改过任意设置；返回后必须以当前磁盘内容为基底。
                let currentSettings = storageService.loadSettings()
                currentSettings.lastUpdateCheckDate = Date()
                currentSettings.lastFoundReleaseName = release.name ?? release.tag_name
                storageService.saveSettings(currentSettings)
                syncUpdateCheckFields(from: currentSettings)

                let isNewer = updateService.isUpdateAvailable(release)
                if isNewer {
                    // 后台检查只记录候选版本，绝不下载或安装；用户明确确认后才进入安全切换流程。
                    updateService.pendingRelease = release
                    let version = release.name ?? release.tag_name ?? "新版本"
                    updateService.logs.append("发现新版本 \(version)，等待用户确认安装。")
                    Task {
                        await updateService.notifyUserUpdateFound(release)
                    }
                } else {
                    updateService.pendingRelease = nil
                    updateService.logs.append("当前版本 (\(updateService.currentAppVersion)) 已是最新")
                }
            } else {
                // 同样重新读取，避免把请求开始前的旧 settings 快照写回去。
                let currentSettings = storageService.loadSettings()
                currentSettings.lastUpdateCheckDate = Date()
                storageService.saveSettings(currentSettings)
                syncUpdateCheckFields(from: currentSettings)
                updateService.pendingRelease = nil
                updateService.logs.append("未找到符合条件的更新")
            }
        } catch {
            updateService.logs.append("更新检查失败：\(error.localizedDescription)")
        }
    }

    private func syncUpdateCheckFields(from settings: AppSettings) {
        // 只同步本次检查更新的字段，保留用户当前内存中的其他设置和倒计时镜像。
        appSettings.lastUpdateCheckDate = settings.lastUpdateCheckDate
        appSettings.lastFoundReleaseName = settings.lastFoundReleaseName
        appSettings.examCountdowns = examCountdowns
    }
    
    func loadSavedData() {
        materials = storageService.loadMaterials()
        reviewPlans = storageService.loadReviewPlans()
        historyService.reloadProgress()
        if !hasLoadedExamCountdowns {
            isRestoringExamCountdowns = true
            // 优先读独立文件；旧版本数据仍在 settings.json 时做一次性迁移
            var restored = storageService.loadExamCountdowns()
            if restored.isEmpty {
                let settings = storageService.loadSettings()
                restored = settings.examCountdowns
            }
            examCountdowns = restored
            isRestoringExamCountdowns = false
            hasLoadedExamCountdowns = true
            if !restored.isEmpty {
                storageService.saveExamCountdowns(restored)
            }
        }
        appSettings.examCountdowns = examCountdowns
    }
    
    private func performStartupScanIfNeeded(paths: [String]) async {
        guard !isScanning else { return }

        let urls = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { path -> URL in
                if let fileURL = URL(string: path), fileURL.isFileURL {
                    return fileURL
                }
                return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
        guard !urls.isEmpty else { return }

        isScanning = true
        defer { isScanning = false }

        var scannedMaterials: [StudyMaterial] = []
        var unavailablePaths: [String] = []
        let fileManager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                unavailablePaths.append(url.path)
                continue
            }

            if isDirectory.boolValue {
                scannedMaterials.append(
                    contentsOf: await fileScanner.scanDirectory(at: url, storageMode: .copy)
                )
            } else {
                scannedMaterials.append(
                    contentsOf: await fileScanner.scanFiles(urls: [url], storageMode: .copy)
                )
            }
        }

        if !scannedMaterials.isEmpty {
            materials.append(contentsOf: scannedMaterials)
            storageService.saveMaterials(materials)
        }
        if !unavailablePaths.isEmpty {
            errorMessage = "启动扫描失败，以下路径不可用：\(unavailablePaths.joined(separator: "、"))"
            showError = true
        }
    }

    func importFiles(_ urls: [URL], storageMode: MaterialStorageMode = .copy) {
        isScanning = true
        Task {
            let newMaterials = await fileScanner.scanFiles(urls: urls, storageMode: storageMode)
            await MainActor.run {
                materials.append(contentsOf: newMaterials)
                storageService.saveMaterials(materials)
                isScanning = false
            }
        }
    }
    
    func processOCR(for material: StudyMaterial) {
        guard let imageURL = material.localURL else { return }
        isProcessingOCR = true
        
        Task {
            let text = await ocrService.recognizeText(from: imageURL)
            await MainActor.run {
                if let index = materials.firstIndex(where: { $0.id == material.id }) {
                    materials[index].extractedText = text
                    storageService.saveMaterials(materials)
                }
                isProcessingOCR = false
            }
        }
    }
    
    func extractKeywords(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        
        isExtractingKeywords = true
        Task {
            let keywords = keywordService.extractKeywords(from: text)
            await MainActor.run {
                if let index = materials.firstIndex(where: { $0.id == material.id }) {
                    materials[index].keywords = keywords
                    storageService.saveMaterials(materials)
                }
                extractedKeywords = keywords
                isExtractingKeywords = false
            }
        }
    }
    
    func analyzeWithAI(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else {
            errorMessage = "没有可分析的文本内容"
            showError = true
            return
        }
        
        guard appSettings.llmConfiguration.enabled else {
            errorMessage = "请先在设置中启用 AI 分析功能"
            showError = true
            return
        }
        
        isAnalyzingWithAI = true
        aiAnalysisResult = ""
        
        Task {
            do {
                let result = try await llmService.analyzeText(text)
                await MainActor.run {
                    aiAnalysisResult = result
                    isAnalyzingWithAI = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAnalyzingWithAI = false
                }
            }
        }
    }
    
    func generateSummaryWithAI(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        guard appSettings.llmConfiguration.enabled else { return }
        
        isAnalyzingWithAI = true
        aiAnalysisResult = ""
        
        Task {
            do {
                let result = try await llmService.generateSummary(text)
                await MainActor.run {
                    aiAnalysisResult = result
                    isAnalyzingWithAI = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                    isAnalyzingWithAI = false
                }
            }
        }
    }
    
    func createReviewPlan(examDate: Date, subject: String, topics: [String]) {
        let plan = calendarService.generateReviewPlan(
            examDate: examDate,
            subject: subject,
            topics: topics
        )
        reviewPlans.append(plan)
        storageService.saveReviewPlans(reviewPlans)
        
        Task {
            await calendarService.createCalendarEvents(for: plan)
        }
    }
    
    func deleteMaterial(_ material: StudyMaterial) {
        materials.removeAll { $0.id == material.id }
        storageService.saveMaterials(materials)
    }

    // 删除多个资料（批量操作）
    func deleteMaterials(withIDs ids: [UUID]) {
        materials.removeAll { ids.contains($0.id) }
        storageService.saveMaterials(materials)
    }
    
    var filteredMaterials: [StudyMaterial] {
        if searchText.isEmpty {
            return materials
        }
        return materials.filter { material in
            material.name.localizedCaseInsensitiveContains(searchText) ||
            (material.keywords?.contains { $0.localizedCaseInsensitiveContains(searchText) } ?? false) ||
            (material.content.localizedCaseInsensitiveContains(searchText))
        }
    }
}
