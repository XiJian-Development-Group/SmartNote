import SwiftUI
import Combine

@MainActor
class AppState_macOS: ObservableObject {
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
            if appSettings.examCountdowns != examCountdowns {
                appSettings.examCountdowns = examCountdowns
            }
        }
    }
    @Published private(set) var activeThemeID: AppSettings.ThemeID = .classic
    @Published private(set) var activeDarkModePreference: AppSettings.DarkModePreference = .system
    @Published private(set) var isNationalDayPeriod: Bool = false
    @Published private(set) var lastStartupMigration: StartupMigrationResult?

    var shouldShowBlessingBar: Bool { theme.isFestive || isNationalDayPeriod }
    var colorScheme: ColorScheme? {
        activeThemeID == .classic ? activeDarkModePreference.colorScheme : theme.colorScheme
    }
    var theme: AppTheme { AppTheme.theme(for: activeThemeID) }

    var llmConfiguration: LLMConfiguration {
        get { appSettings.llmConfiguration }
        set {
            appSettings.llmConfiguration = newValue
            storageService.saveSettings(appSettings)
            llmService.updateConfiguration(newValue)
        }
    }

    // 平台专用服务
    let fileScanner = FileScannerService()
    let ocrService = OCRService()
    let keywordService = KeywordExtractionService()
    let calendarService = CalendarService()
    let backupService: BackupService
    let fileCryptoService = FileCryptoService()
    let launchAtLoginService = LaunchAtLoginService()
    let ambientSoundService = AmbientSoundService()
    let wishService = WishService()
    // 纪念日服务需要显式的通知实现；`init` 早于属性初始化式，因此在此用平台单例。
    let anniversaryService = AnniversaryService(notification: NotificationService.shared)
    let calculatorEngine = CalculatorEngine()
    let answerBookService = AnswerBookService()
    let speechService = SpeechService.shared
    let learningAnalysisService = LearningAnalysisService.shared
    let notificationService = NotificationService.shared
    let updateService: UpdateService
    let blessingService: BlessingService
    let historyService: HistoryService

    // 共享层服务（需要平台注入）
    let storageService: StorageService
    let keychainService: KeychainStoring
    var updateCheckCancellable: AnyCancellable? = nil
    var llmService: LLMService
    private var hasLoadedExamCountdowns: Bool = false
    private var isRestoringExamCountdowns: Bool = false
    private var storageClearObserver: NSObjectProtocol?
    private var appSettingsCancellable: AnyCancellable?
    private var nestedCancellables: [AnyCancellable] = []

    init() {
        // 0. 注册本平台的通知实现，供 Shared 层仓库服务使用
        //    （TodoService / HabitService / AnniversaryService / PomodoroTimer）。
        //    必须在任何 Shared 服务发起通知之前完成。
        //    这里直接引用单例而非属性 `notificationService`：属性初始化式
        //    早于 init 体执行，init 里读取 `self` 的属性尚未可用。
        // 注册本平台的文字识别实现，供 Shared 层的 LLMService /
        // LearningAnalysisService 使用。
        PlatformTextRecognizer.register(OCRService.shared)

        PlatformNotificationService.register(NotificationService.shared)

        // 1. 先设置默认钥匙串，再创建 StorageService
        let ks = KeychainService_macOS()
        self.keychainService = ks
        StorageService.defaultKeychainService = ks
        let probeStorage = StorageService()
        
        let migrationResult = probeStorage.runStartupMigration()
        let settings = probeStorage.loadSettings()

        self.backupService = BackupService(sourceRoot: probeStorage.appSupportURL)
        let config = settings.llmConfiguration
        // LLMService 需要平台 OCR 服务 - OCRService 需要符合 TextRecognizing
        // 暂时传 nil，后续实现 TextRecognizing
        self.llmService = LLMService(configuration: config, ocrService: ocrService)
        self.updateService = UpdateService(owner: settings.updateRepoOwner, repo: settings.updateRepoName)
        self.blessingService = BlessingService()
        self.isNationalDayPeriod = blessingService.isNationalDayPeriod
        self.historyService = HistoryService(storageService: probeStorage)
        self.storageService = probeStorage  // 复用 probeStorage，避免重复创建
        self.appSettings = settings
        self.activeThemeID = settings.themeID
        self.activeDarkModePreference = settings.darkModePreference
        self.lastStartupMigration = migrationResult
        loadSavedData()
        prepareBackgroundImage()

        if settings.autoScanDirectories && !settings.scanPaths.isEmpty {
            let startupScanPaths = settings.scanPaths
            Task { [weak self] in
                await self?.performStartupScanIfNeeded(paths: startupScanPaths)
            }
        }

        storageClearObserver = NotificationCenter.default.addObserver(
            forName: .storageDidClearAllData, object: nil, queue: .main
        ) { [weak self] _ in self?.loadSavedData() }

        rebindAppSettingsObservation()
        forwardNestedChanges(of: ambientSoundService)
        forwardNestedChanges(of: wishService)
        forwardNestedChanges(of: anniversaryService)
        forwardNestedChanges(of: blessingService)
        forwardNestedChanges(of: historyService)
        forwardNestedChanges(of: answerBookService)
        forwardNestedChanges(of: speechService)
        forwardNestedChanges(of: notificationService)
        forwardNestedChanges(of: learningAnalysisService)
        forwardNestedChanges(of: updateService)
        forwardNestedChanges(of: launchAtLoginService)

        MainActor.assumeIsolated { SharedAppStateProxy.shared.bind(self) }

        if settings.autoUpdateEnabled {
            Task { await performAutoCheckIfEnabled() }
        }
        scheduleUpdateChecks(hoursInterval: settings.updateCheckIntervalHours)
    }

    // MARK: - 嵌套 ObservableObject 转发

    private func rebindAppSettingsObservation() {
        appSettingsCancellable = appSettings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    private func forwardNestedChanges<T: ObservableObject>(of service: T) {
        nestedCancellables.append(
            service.objectWillChange
                .eraseToAnyPublisher()
                .sink { [weak self] _ in self?.objectWillChange.send() }
        )
    }

    // MARK: - 公共功能方法（从原有 AppState 迁移）

    func refreshSettings() {
        let currentExamCountdowns = examCountdowns
        let loadedSettings = storageService.loadSettings()
        self.appSettings = loadedSettings
        rebindAppSettingsObservation()
        self.activeThemeID = loadedSettings.themeID
        self.activeDarkModePreference = loadedSettings.darkModePreference
        self.appSettings.examCountdowns = currentExamCountdowns
    }

    func setTheme(_ themeID: AppSettings.ThemeID) {
        guard activeThemeID != themeID else { return }
        appSettings.themeID = themeID
        activeThemeID = themeID
        applyThemeBackgroundLock(for: themeID)
        storageService.saveSettings(appSettings)
    }

    private func applyThemeBackgroundLock(for themeID: AppSettings.ThemeID) {
        let target = AppTheme.theme(for: themeID)
        guard let bundled = target.bundledBackgroundName else {
            appSettings.backgroundImageActiveName = appSettings.backgroundImageName
            return
        }
        if !storageService.installBundledBackground(named: bundled) {
            restorationFailedBundledImage = bundled
            return
        }
        appSettings.backgroundImageEnabled = true
        appSettings.backgroundImageRandomEnabled = false
        appSettings.backgroundImageName = bundled
        appSettings.backgroundImageActiveName = bundled
        if !appSettings.backgroundImageLibrary.contains(bundled) {
            appSettings.backgroundImageLibrary.append(bundled)
        }
    }

    @Published private(set) var restorationFailedBundledImage: String?

    @Published var wishWindowRequestToken: Int = 0
    func deliverWishWindowRequest() { wishWindowRequestToken &+= 1 }

    func prepareBackgroundImage() {
        storageService.restoreBundledBackgroundsIfMissing()
        let bundled = theme.bundledBackgroundName
        if let bundled {
            if !storageService.installBundledBackground(named: bundled) {
                restorationFailedBundledImage = bundled
            } else {
                appSettings.backgroundImageEnabled = true
                appSettings.backgroundImageRandomEnabled = false
                appSettings.backgroundImageName = bundled
                appSettings.backgroundImageActiveName = bundled
                if !appSettings.backgroundImageLibrary.contains(bundled) {
                    appSettings.backgroundImageLibrary.append(bundled)
                }
            }
        } else {
            restorationFailedBundledImage = nil
        }
        syncBackgroundImageLibrary()
        if bundled == nil {
            if appSettings.backgroundImageEnabled {
                if appSettings.backgroundImageRandomEnabled {
                    pickRandomBackgroundImage(excluding: appSettings.backgroundImageActiveName)
                    return
                } else if appSettings.backgroundImageActiveName == nil {
                    appSettings.backgroundImageActiveName = appSettings.backgroundImageName
                }
            }
        }
        storageService.saveSettings(appSettings)
    }

    func syncBackgroundImageLibrary() {
        let onDisk = storageService.listBackgroundImages()
        guard !onDisk.isEmpty else { return }
        var merged = onDisk
        for bundled in StorageService.bundledBackgroundNames where !merged.contains(bundled) {
            merged.append(bundled)
        }
        if appSettings.backgroundImageLibrary.sorted() != merged.sorted() {
            appSettings.backgroundImageLibrary = merged
        }
    }

    var isBackgroundLockedByTheme: Bool { theme.bundledBackgroundName != nil }
    var lockedBundledBackgroundName: String? { theme.bundledBackgroundName }

    func clearRestorationFailure() { restorationFailedBundledImage = nil }

    @discardableResult
    func addBackgroundImage(_ fileName: String) -> Bool {
        guard !isBackgroundLockedByTheme else { return false }
        if appSettings.backgroundImageLibrary.contains(fileName) {
            appSettings.backgroundImageName = fileName
            if !appSettings.backgroundImageRandomEnabled {
                appSettings.backgroundImageActiveName = fileName
            }
            storageService.saveSettings(appSettings)
            return true
        }
        appSettings.backgroundImageLibrary.append(fileName)
        appSettings.backgroundImageEnabled = true
        appSettings.backgroundImageName = fileName
        if !appSettings.backgroundImageRandomEnabled {
            appSettings.backgroundImageActiveName = fileName
        }
        storageService.saveSettings(appSettings)
        return true
    }

    func selectBackgroundImage(_ fileName: String) {
        guard !isBackgroundLockedByTheme else { return }
        appSettings.backgroundImageName = fileName
        appSettings.backgroundImageActiveName = fileName
        storageService.saveSettings(appSettings)
    }

    func removeBackgroundImage(_ fileName: String) {
        guard !StorageService.isBundledBackground(fileName) else { return }
        appSettings.backgroundImageLibrary.removeAll { $0 == fileName }
        if appSettings.backgroundImageName == fileName {
            appSettings.backgroundImageName = appSettings.backgroundImageLibrary.first
        }
        if appSettings.backgroundImageActiveName == fileName {
            appSettings.backgroundImageActiveName = appSettings.backgroundImageLibrary.first
        }
        storageService.deleteBackgroundImage(named: fileName)
        storageService.saveSettings(appSettings)
    }

    func clearUserBackgroundLibrary() {
        for name in appSettings.backgroundImageLibrary where !StorageService.isBundledBackground(name) {
            storageService.deleteBackgroundImage(named: name)
        }
        storageService.restoreBundledBackgroundsIfMissing()
        syncBackgroundImageLibrary()
        if isBackgroundLockedByTheme {
            if let bundled = theme.bundledBackgroundName {
                appSettings.backgroundImageName = bundled
                appSettings.backgroundImageActiveName = bundled
            }
        } else {
            let userImages = appSettings.backgroundImageLibrary.filter { !StorageService.isBundledBackground($0) }
            appSettings.backgroundImageName = userImages.first
            appSettings.backgroundImageActiveName = userImages.first
            appSettings.backgroundImageRandomEnabled = false
            if userImages.isEmpty { appSettings.backgroundImageEnabled = false }
        }
        storageService.saveSettings(appSettings)
    }

    func setBackgroundImageRandomEnabled(_ enabled: Bool) {
        guard !isBackgroundLockedByTheme else {
            appSettings.backgroundImageRandomEnabled = false
            storageService.saveSettings(appSettings)
            return
        }
        appSettings.backgroundImageRandomEnabled = enabled
        if enabled { pickRandomBackgroundImage(excluding: appSettings.backgroundImageActiveName) }
        else { appSettings.backgroundImageActiveName = appSettings.backgroundImageName }
    }

    func pickRandomBackgroundImage(excluding exclude: String? = nil) {
        guard !isBackgroundLockedByTheme else { return }
        syncBackgroundImageLibrary()
        let userLibrary = appSettings.backgroundImageLibrary.filter { !StorageService.isBundledBackground($0) }
        guard !userLibrary.isEmpty else {
            appSettings.backgroundImageActiveName = appSettings.backgroundImageName
            storageService.saveSettings(appSettings)
            return
        }
        let candidates = userLibrary.filter { $0 != exclude }
        let pool = candidates.isEmpty ? userLibrary : candidates
        appSettings.backgroundImageActiveName = pool.randomElement()
        storageService.saveSettings(appSettings)
    }

    func flushPendingChangesBeforeTerminate() {
        storageService.saveMaterials(materials)
        storageService.saveReviewPlans(reviewPlans)
        storageService.saveSettings(appSettings)
        historyService.flushProgress()
        WhiteboardService.shared.flushPendingSave()
    }

    func setDarkModePreference(_ preference: AppSettings.DarkModePreference) {
        guard activeDarkModePreference != preference else { return }
        appSettings.darkModePreference = preference
        activeDarkModePreference = preference
        storageService.saveSettings(appSettings)
    }

    func updateUpdateServiceRepositoryIfNeeded(owner: String, repo: String) {
        updateService.updateRepository(owner: owner, repo: repo)
    }

    func scheduleUpdateChecks(hoursInterval: Int) {
        updateCheckCancellable?.cancel()
        let interval = max(1, hoursInterval)
        updateCheckCancellable = Timer.publish(every: TimeInterval(interval * 3600), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { await self?.performAutoCheckIfEnabled() } }
    }

    func performAutoCheckIfEnabled() async {
        let settings = storageService.loadSettings()
        guard settings.autoUpdateEnabled else { return }
        let channel: UpdateService.Channel = (settings.updateChannel == .prerelease) ? .prerelease : .latest
        do {
            if let release = try await updateService.checkForUpdate(channel: channel) {
                let currentSettings = storageService.loadSettings()
                currentSettings.lastUpdateCheckDate = Date()
                currentSettings.lastFoundReleaseName = release.name ?? release.tag_name
                storageService.saveSettings(currentSettings)
                syncUpdateCheckFields(from: currentSettings)

                let isNewer = updateService.isUpdateAvailable(release)
                if isNewer {
                    updateService.pendingRelease = release
                    let version = release.name ?? release.tag_name ?? "新版本"
                    updateService.logs.append("发现新版本 \(version)，等待用户确认安装。")
                    Task { await updateService.notifyUserUpdateFound(release) }
                } else {
                    updateService.pendingRelease = nil
                    updateService.logs.append("当前版本 (\(updateService.currentAppVersion)) 已是最新")
                }
            } else {
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
        appSettings.lastUpdateCheckDate = settings.lastUpdateCheckDate
        appSettings.lastFoundReleaseName = settings.lastFoundReleaseName
        appSettings.examCountdowns = examCountdowns
    }

    func loadSavedData() {
        materials = storageService.loadMaterials()
        reviewPlans = storageService.loadReviewPlans()
        historyService.reloadProgress()
        answerBookService.reloadHistory()
        isNationalDayPeriod = blessingService.isNationalDayPeriod
        if !hasLoadedExamCountdowns {
            isRestoringExamCountdowns = true
            var restored = storageService.loadExamCountdowns()
            if restored.isEmpty {
                let settings = storageService.loadSettings()
                restored = settings.examCountdowns
            }
            examCountdowns = restored
            isRestoringExamCountdowns = false
            hasLoadedExamCountdowns = true
            if !restored.isEmpty { storageService.saveExamCountdowns(restored) }
        }
        appSettings.examCountdowns = examCountdowns
    }

    private func performStartupScanIfNeeded(paths: [String]) async {
        guard !isScanning else { return }
        let urls = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { path -> URL in
                if let fileURL = URL(string: path), fileURL.isFileURL { return fileURL }
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
                unavailablePaths.append(url.path); continue
            }
            if isDirectory.boolValue {
                scannedMaterials.append(contentsOf: await fileScanner.scanDirectory(at: url, storageMode: .copy))
            } else {
                scannedMaterials.append(contentsOf: await fileScanner.scanFiles(urls: [url], storageMode: .copy))
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
        guard !text.isEmpty else { errorMessage = "没有可分析的文本内容"; showError = true; return }
        guard appSettings.llmConfiguration.enabled else { errorMessage = "请先在设置中启用 AI 分析功能"; showError = true; return }
        isAnalyzingWithAI = true; aiAnalysisResult = ""
        Task {
            do {
                let result = try await llmService.analyzeText(text)
                await MainActor.run { aiAnalysisResult = result; isAnalyzingWithAI = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; showError = true; isAnalyzingWithAI = false }
            }
        }
    }

    func generateSummaryWithAI(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        guard !text.isEmpty else { return }
        guard appSettings.llmConfiguration.enabled else { return }
        isAnalyzingWithAI = true; aiAnalysisResult = ""
        Task {
            do {
                let result = try await llmService.generateSummary(text)
                await MainActor.run { aiAnalysisResult = result; isAnalyzingWithAI = false }
            } catch {
                await MainActor.run { errorMessage = error.localizedDescription; showError = true; isAnalyzingWithAI = false }
            }
        }
    }

    func createReviewPlan(examDate: Date, subject: String, topics: [String]) {
        let plan = calendarService.generateReviewPlan(examDate: examDate, subject: subject, topics: topics)
        reviewPlans.append(plan)
        storageService.saveReviewPlans(reviewPlans)
        Task { await calendarService.createCalendarEvents(for: plan) }
    }

    func deleteMaterial(_ material: StudyMaterial) {
        materials.removeAll { $0.id == material.id }
        storageService.saveMaterials(materials)
    }

    func deleteMaterials(withIDs ids: [UUID]) {
        materials.removeAll { ids.contains($0.id) }
        storageService.saveMaterials(materials)
    }

    var filteredMaterials: [StudyMaterial] {
        if searchText.isEmpty { return materials }
        return materials.filter { material in
            material.name.localizedCaseInsensitiveContains(searchText) ||
            (material.keywords?.contains { $0.localizedCaseInsensitiveContains(searchText) } ?? false) ||
            material.content.localizedCaseInsensitiveContains(searchText)
        }
    }
}