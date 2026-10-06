import SwiftUI
import Combine
import UserNotifications
import BackgroundTasks

@MainActor
class AppState_iOS: ObservableObject {
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

    // iOS 专用状态
    @Published var isScanningDocument: Bool = false
    @Published var isRecordingVoice: Bool = false
    @Published var showCameraScanner: Bool = false
    @Published var showVoiceMemo: Bool = false
    @Published var pushNotificationToken: String?
    @Published var isICloudSyncEnabled: Bool = false

    /// 当前签名是否带 iCloud 能力。
    ///
    /// 个人（免费）开发者账号无法生成带 iCloud 能力的描述文件，
    /// 此时 `project.yml` 已注释掉 iCloud entitlement。界面据此隐藏同步开关，
    /// 避免给用户一个「按了必然报错」的选项。
    var isCloudKitAvailable: Bool { iCloudSyncService.isAvailable }
    @Published var lastSyncDate: Date?
    @Published var syncStatus: SyncStatus = .idle

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

    // 共享服务
    let ocrService = OCRService_iOS.shared
    let keywordService = KeywordExtractionService()
    let calendarService = CalendarService()
    let backupService: BackupService
    let fileCryptoService = FileCryptoService()
    let ambientSoundService = AmbientSoundService()
    let wishService = WishService()
    let anniversaryService: AnniversaryService
    let habitService = HabitService()
    let calculatorEngine = CalculatorEngine()
    let answerBookService = AnswerBookService()
    let speechService = SpeechService_iOS.shared
    let learningAnalysisService = LearningAnalysisService.shared
    let notificationService = NotificationService_iOS.shared
    let updateService: UpdateService
    let blessingService: BlessingService
    let historyService: HistoryService

    // iOS 专用服务
    let documentScannerService = DocumentScannerService_iOS()
    let voiceMemoService = VoiceMemoService()
    /// 资料导入/扫描。iOS 通过 `fileImporter` 让用户选文件，
    /// macOS 则用目录扫描——两者共用同一个 `AppState` 入口，因此这里
    /// 持有的是 iOS 实现。
    let fileScanner = FileScannerService_iOS()
    let pushNotificationService = PushNotificationService.shared
    let iCloudSyncService = ICloudSyncService()
    let shortcutsProvider = ShortcutsProvider()
    let spotlightIndexer = SpotlightIndexer.shared
    let hapticFeedbackService = HapticFeedbackService.shared
    let backgroundTaskService = BackgroundTaskService.shared

    // 共享层服务（需要平台注入）
    let storageService: StorageService
    let keychainService: KeychainStoring
    var updateCheckCancellable: AnyCancellable? = nil
    var llmService: LLMService
    private var hasLoadedExamCountdowns: Bool = false
    private var isRestoringExamCountdowns: Bool = false
    private var storageClearObserver: NSObjectProtocol?
    /// 等待 CloudKit 账号/能力状态落定的短任务；仅用于启动时的一次性判断。
    private var cloudKitStatusTask: Task<Void, Never>?
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
        PlatformTextRecognizer.register(OCRService_iOS.shared)

        PlatformNotificationService.register(NotificationService_iOS.shared)

        // 1. 先设置默认钥匙串，再创建 StorageService
        let ks = KeychainService_iOS()
        self.keychainService = ks
        StorageService.defaultKeychainService = ks
        let probeStorage = StorageService()
        
        let migrationResult = probeStorage.runStartupMigration()
        let settings = probeStorage.loadSettings()

        self.backupService = BackupService(sourceRoot: probeStorage.appSupportURL)
        let config = settings.llmConfiguration
        self.llmService = LLMService(configuration: config, ocrService: ocrService)
        self.updateService = UpdateService(owner: settings.updateRepoOwner, repo: settings.updateRepoName)
        self.blessingService = BlessingService()
        self.isNationalDayPeriod = blessingService.isNationalDayPeriod
        self.historyService = HistoryService(storageService: probeStorage)
        self.anniversaryService = AnniversaryService(notification: notificationService)
        self.storageService = probeStorage
        self.appSettings = settings
        self.activeThemeID = settings.themeID
        self.activeDarkModePreference = settings.darkModePreference
        self.lastStartupMigration = migrationResult
        loadSavedData()
        prepareBackgroundImage()

        // iOS 专用初始化
        setupPushNotifications()
        setupICloudSync()
        setupShortcuts()
        setupSpotlightIndexing()
        registerBackgroundTasks()

        if settings.autoScanDirectories && !settings.scanPaths.isEmpty {
            let startupScanPaths = settings.scanPaths
            Task { [weak self] in await self?.performStartupScanIfNeeded(paths: startupScanPaths) }
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
        forwardNestedChanges(of: pushNotificationService)
        forwardNestedChanges(of: iCloudSyncService)
        forwardNestedChanges(of: backgroundTaskService)

        // 注：macOS 用 `SharedAppStateProxy` 把通知点击/快捷指令路由回主界面，
        // 它绑定的是 `AppState_macOS`。iOS 端由 SwiftUI 的 `onOpenURL` 与
        // `onContinueUserActivity` 直接驱动，不复用该代理。

        if settings.autoUpdateEnabled {
            Task { await performAutoCheckIfEnabled() }
        }
        scheduleUpdateChecks(hoursInterval: settings.updateCheckIntervalHours)
    }
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case success(Date)
        case failed(Error)
        static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.syncing, .syncing): return true
            case (.success(let d1), .success(let d2)): return d1 == d2
            case (.failed(let e1), .failed(let e2)): return e1.localizedDescription == e2.localizedDescription
            default: return false
            }
        }
    }



    // MARK: - iOS 专用设置

    private func setupPushNotifications() {
        // 通知点击 → 切换到对应标签页。macOS 通过 `SharedAppStateProxy` 定位窗口，
        // iOS 由选中的 Tab 承载，因此直接在这里路由。
        pushNotificationService.onNotificationTapped = { [weak self] userInfo in
            guard let self else { return }
            self.routeNotification(userInfo)
        }

        Task {
            let granted = await pushNotificationService.requestAuthorization()
            if granted {
                pushNotificationToken = await pushNotificationService.getDeviceToken()
                // 注册到服务器（如果有）
            }
        }
    }

    /// 根据通知的 `kind` 字段跳转到相应标签页。
    ///
    /// 只做导航，不读取任何正文——详情由目标页面按 `userInfo` 里的 ID 自行查询。
    private func routeNotification(_ userInfo: [String: Any]) {
        switch userInfo["kind"] as? String {
        case "todo": selectedTab = 2
        case "habit": selectedTab = 3
        case "anniversary": selectedTab = 4
        case "review": selectedTab = 5
        case "pomodoro": selectedTab = 9
        default: break
        }
    }

    private func setupICloudSync() {
        iCloudSyncService.delegate = self

        // `isCloudKitAvailable` 要等 `accountStatus` 回调才有结论，
        // 这里先按「已开启但能力未知」处理，收到结论后由
        // `applyCloudKitAvailability()` 决定是否真正同步。
        isICloudSyncEnabled = appSettings.iCloudSyncEnabled
        observeCloudKitAvailability()
    }

    /// 监听账号/能力状态变化。
    ///
    /// 一旦确认没有 iCloud 能力，就把已保存的开关关掉并停止一切同步尝试，
    /// 避免每次回到前台都失败一次。
    private func observeCloudKitAvailability() {
        cloudKitStatusTask?.cancel()
        cloudKitStatusTask = Task { [weak self] in
            guard let self else { return }
            // 轮询到状态稳定即可：accountStatus 是冷启动时一次性回调的，
            // 短时间内观察到非 .couldNotDetermine 就说明有结论。
            for _ in 0..<10 {
                if !Task.isCancelled, await self.settledCloudKitAvailability() {
                    self.applyCloudKitAvailability()
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func settledCloudKitAvailability() -> Bool {
        iCloudSyncService.accountStatus != .couldNotDetermine
    }

    private func applyCloudKitAvailability() {
        guard !isCloudKitAvailable, isICloudSyncEnabled else { return }
        isICloudSyncEnabled = false
        appSettings.iCloudSyncEnabled = false
        storageService.saveSettings(appSettings)
        syncStatus = .idle
    }

    private func setupShortcuts() {
        shortcutsProvider.updateShortcuts(basedOn: appSettings)
    }

    private func setupSpotlightIndexing() {
        Task { await spotlightIndexer.indexAll(materials: materials, diaries: [], wrongQuestions: []) }
    }

    private func registerBackgroundTasks() {
        backgroundTaskService.registerTasks()
    }

    // MARK: - 生命周期

    func applicationDidBecomeActive() {
        UIApplication.shared.applicationIconBadgeNumber = 0
        // 能力缺失时不尝试同步：否则每次切回前台都会弹一次错误。
        if isICloudSyncEnabled && isCloudKitAvailable {
            Task { await performICloudSync() }
        }
        shortcutsProvider.updateShortcuts(basedOn: appSettings)
    }

    func applicationWillResignActive() {
        flushPendingChangesBeforeTerminate()
    }

    func applicationDidEnterBackground() {
        flushPendingChangesBeforeTerminate()
        backgroundTaskService.scheduleAppRefresh()
        backgroundTaskService.scheduleBackgroundSync()
    }

    func handleDeepLink(_ url: URL) {
        // smartnote://tab/3 等深度链接处理
        guard url.scheme == "smartnote" else { return }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.first == "tab", let tabIndex = Int(components.dropFirst().first ?? "") {
            selectedTab = tabIndex
        } else if components.first == "newMaterial" {
            showFileImporter = true
        } else if components.first == "newDiary" {
            // 打开日记编辑器
        } else if components.first == "pomodoro" {
            selectedTab = 9 // 番茄钟 tab 索引
        }
    }

    func handleHandoff(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        handleDeepLink(url)
    }

    // MARK: - iCloud 同步

    func toggleICloudSync(_ enabled: Bool) {
        guard enabled else {
            appSettings.iCloudSyncEnabled = false
            isICloudSyncEnabled = false
            storageService.saveSettings(appSettings)
            return
        }

        guard isCloudKitAvailable else {
            errorMessage = ICloudSyncService.SyncError.capabilityUnavailable.localizedDescription
            showError = true
            hapticFeedbackService.error()
            return
        }

        appSettings.iCloudSyncEnabled = true
        isICloudSyncEnabled = true
        storageService.saveSettings(appSettings)
        Task { await performICloudSync() }
    }

    func performICloudSync() async {
        syncStatus = .syncing
        do {
            try await iCloudSyncService.syncAll(
                materials: materials,
                reviewPlans: reviewPlans,
                examCountdowns: examCountdowns
            )
            // 设置项不做同步：里面含设备相关的路径与钥匙串引用，
            // 跨设备照搬会让另一台机器指向不存在的路径。
            lastSyncDate = iCloudSyncService.lastSyncDate ?? Date()
            syncStatus = .success(lastSyncDate!)
            spotlightIndexer.indexAll(materials: materials, diaries: [], wrongQuestions: [])
            hapticFeedbackService.success()
        } catch {
            syncStatus = .failed(error)
            hapticFeedbackService.error()
        }
    }

    /// 从 iCloud 拉回远端记录，并按「远端覆盖本机同 ID 记录」的规则合并。
    ///
    /// 合并策略刻意保持保守：以本机为主，仅补充本机没有的实体。
    /// 这样一次误触同步不会覆盖用户刚在本地做的编辑。
    func pullFromICloud() async {
        syncStatus = .syncing
        do {
            let pulled = try await iCloudSyncService.pullAll()
            merge(pulled)
            lastSyncDate = iCloudSyncService.lastSyncDate ?? Date()
            syncStatus = .success(lastSyncDate!)
            hapticFeedbackService.success()
        } catch {
            syncStatus = .failed(error)
            hapticFeedbackService.error()
        }
    }

    private func merge(_ pulled: ICloudSyncService.PulledRecords) {
        let existingMaterialIDs = Set(materials.map(\.id))
        materials.append(contentsOf: pulled.materials.filter { !existingMaterialIDs.contains($0.id) })

        let existingPlanIDs = Set(reviewPlans.map(\.id))
        reviewPlans.append(contentsOf: pulled.reviewPlans.filter { !existingPlanIDs.contains($0.id) })

        let existingExamIDs = Set(examCountdowns.map(\.id))
        examCountdowns.append(contentsOf: pulled.examCountdowns.filter { !existingExamIDs.contains($0.id) })

        storageService.saveMaterials(materials)
        storageService.saveReviewPlans(reviewPlans)
        storageService.saveExamCountdowns(examCountdowns)
    }

    // MARK: - 相机扫描 / 语音备忘

    func startDocumentScan() {
        isScanningDocument = true
        showCameraScanner = true
        hapticFeedbackService.light()
    }

    func finishDocumentScan(images: [UIImage]) {
        isScanningDocument = false
        showCameraScanner = false
        Task {
            let pdfData = await documentScannerService.createPDF(from: images)
            if let data = pdfData {
                await importScannedPDF(data)
            }
        }
    }

    /// 打开语音备忘面板。录音本身由 `VoiceMemoView` 内的 `VoiceMemoService`
    /// 驱动（需要实时电平/计时反馈），因此这里不再代为启动录音。
    func startVoiceMemo() {
        isRecordingVoice = false
        showVoiceMemo = true
        hapticFeedbackService.light()
    }

    /// 把一段语音转写结果保存为学习资料。
    ///
    /// 音频文件保留在资料目录里，`content` 为转写文本，音频路径写入
    /// `localURL`，方便之后在资料详情里回放。
    func saveVoiceMemoTranscript(_ text: String, audioURL: URL) async {
        let material = StudyMaterial(
            name: "语音笔记_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
            type: .text,
            localURL: audioURL,
            content: text
        )
        materials.insert(material, at: 0)
        storageService.saveMaterials(materials)
        hapticFeedbackService.success()
    }

    private func importScannedPDF(_ data: Data) async {
        let fileName = "扫描文档_\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)).pdf"
        let url = storageService.getMaterialsDirectory().appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            let material = StudyMaterial(name: fileName, type: .pdf, localURL: url, content: "")
            await MainActor.run {
                materials.insert(material, at: 0)
                storageService.saveMaterials(materials)
                hapticFeedbackService.success()
            }
        } catch {
            await MainActor.run {
                errorMessage = "保存扫描文档失败：\(error.localizedDescription)"
                showError = true
                hapticFeedbackService.error()
            }
        }
    }


    // MARK: - 共享逻辑（从 macOS 复用并适配）

    private func rebindAppSettingsObservation() {
        appSettingsCancellable = appSettings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    private func forwardNestedChanges<T: ObservableObject>(of service: T) {
        nestedCancellables.append(
            service.objectWillChange.eraseToAnyPublisher()
                .sink { [weak self] _ in self?.objectWillChange.send() }
        )
    }

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
        hapticFeedbackService.selection()
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
        } else { restorationFailedBundledImage = nil }
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
        // 注：白板功能目前只有 macOS 实现（见 `Platforms/macOS/Services/WhiteboardService.swift`），
        // iOS 端对应入口展示为 `WhiteboardUnavailableView`，因此这里无需冲刷白板数据。
    }

    func setDarkModePreference(_ preference: AppSettings.DarkModePreference) {
        guard activeDarkModePreference != preference else { return }
        appSettings.darkModePreference = preference
        activeDarkModePreference = preference
        storageService.saveSettings(appSettings)
        hapticFeedbackService.selection()
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

    /// 数据目录被整体替换后，重新从磁盘载入内存中的全部数据。
    ///
    /// 备份恢复（以及 macOS 的同类路径）会直接换掉数据根目录，
    /// 因此必须重载一次，否则界面仍在展示恢复前的旧内容。
    func reloadAfterRestore() {
        loadSavedData()
        prepareBackgroundImage()
        hapticFeedbackService.success()
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
            // `MaterialStorageMode` 是模型上的持久化取值，
            // `FileScannerService_iOS.StorageMode` 是导入过程中的操作参数；
            // 两者语义一致，此处显式映射而不是让服务依赖模型类型。
            let scanMode: FileScannerService_iOS.StorageMode = (storageMode == .copy) ? .copy : .reference
            let newMaterials = await fileScanner.scanFiles(urls: urls, storageMode: scanMode)
            await MainActor.run {
                materials.append(contentsOf: newMaterials)
                storageService.saveMaterials(materials)
                isScanning = false
                hapticFeedbackService.success()
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

// MARK: - iCloudSyncServiceDelegate

extension AppState_iOS: ICloudSyncServiceDelegate {
    func iCloudSyncDidChange(_ service: ICloudSyncService) {
        Task { await performICloudSync() }
    }

    func iCloudSyncDidFail(_ service: ICloudSyncService, error: Error) {
        syncStatus = .failed(error)
    }
}