import SwiftUI
import Combine
import UserNotifications

@MainActor
class AppState_iOS: ObservableObject {
    @Published var selectedTab: Int = 0
    /// iPhone 底部标签栏当前选中项。**与 `selectedTab` 是两套独立编号。**
    ///
    /// 之前两种布局共用 `selectedTab`，编号含义却完全不同：
    /// iPhone 是「资料库/学习/计划/工具/历史/设置」，
    /// iPad 详情区是「全部资料/课件/真题/笔记/收藏/考点提取/…」。
    /// 结果是同一个数字在两端指向不同页面，于是：
    ///   - iPhone 上「课件/真题/笔记/收藏」永远到不了（资料分类不可达）；
    ///   - 通知点击路由（`routeNotification`）在 iPhone 上会跳错页面；
    ///   - `smartnote://tab/N` 深链在 iPhone 上指向错误的 tab；
    ///   - 设为 9（番茄钟）等超出 TabView 范围的编号时完全无反应。
    ///
    /// 现在拆开：iPhone 用 `iphoneTab`，iPad 继续用 `selectedTab`。
    @Published var iphoneTab: IPhoneTab = .materials
    /// iPhone 底部标签栏。
    enum IPhoneTab: Int, Hashable, CaseIterable {
        case materials = 0
        case study
        case plans
        case tools
        case history
        case settings
    }
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
    let shortcutsProvider = ShortcutsProvider()
    let spotlightIndexer = SpotlightIndexer.shared
    let hapticFeedbackService = HapticFeedbackService.shared

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
        setupShortcuts()
        setupSpotlightIndexing()

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
            // 只申请本地通知权限（不需要任何 entitlement）。
            _ = await pushNotificationService.requestAuthorization()
        }
    }

    /// 根据通知的 `kind` 字段跳转到相应页面。
    ///
    /// 只做导航，不读取任何正文——详情由目标页面按 `userInfo` 里的 ID 自行查询。
    ///
    /// 两套布局要分别落到正确的 tab：iPhone 的编号与 iPad 完全不同
    /// （见 `IPhoneTab` 的说明），因此这里两个都写。
    private func routeNotification(_ userInfo: [String: Any]) {
        switch userInfo["kind"] as? String {
        case "todo":
            selectedTab = IPadSection.todo.rawValue
            iphoneTab = .plans
        case "habit":
            selectedTab = IPadSection.habit.rawValue
            iphoneTab = .plans
        case "anniversary":
            selectedTab = IPadSection.anniversary.rawValue
            iphoneTab = .tools
        case "review":
            selectedTab = IPadSection.reviewPlan.rawValue
            iphoneTab = .plans
        case "pomodoro":
            selectedTab = IPadSection.pomodoro.rawValue
            iphoneTab = .study
        default: break
        }
    }

    /// iPad 侧栏/详情区的页面编号。**严格对应 `DetailView_iOS` 里的 `switch`。**
    ///
    /// 以前这些数字只是散落在各处的字面量，于是踩了两个坑：
    ///   - `routeNotification` 认为 9 是番茄钟，实际 9 是**智能阅卷**、10 才是番茄钟；
    ///   - 答案之书的快捷指令写 `selectedTab = 17`，实际 17 是**放松亿下**。
    /// 两处都会跳到完全不相干的页面。
    ///
    /// 另外 `switch` 里本来就**没有 `case 15`**（编号空缺），
    /// 所以这里必须显式写 raw value，不能用隐式递增。
    enum IPadSection: Int {
        case allMaterials = 0
        case lecture = 1
        case exam = 2
        case notes = 3
        case favorites = 4
        case keyPoints = 5
        case reviewPlan = 6
        case statistics = 7
        case aiChat = 8
        case smartGrading = 9
        case pomodoro = 10
        case wrongQuestion = 11
        case flashCard = 12
        case examCountdown = 13
        case duplicateScanner = 14
        /// 15 在 `DetailView_iOS` 中空缺，保留编号不可占用。
        case p2pSocial = 16
        case relaxGame = 17
        case diary = 18
        case whiteboard = 19
        case todo = 20
        case habit = 21
        case fileCrypto = 22
        case whiteNoise = 23
        case answerBook = 24
        case anniversary = 25
        case calculator = 26
        case history = 27
    }

    private func setupShortcuts() {
        shortcutsProvider.updateShortcuts(basedOn: appSettings)
    }

    private func setupSpotlightIndexing() {
        Task { await spotlightIndexer.indexAll(materials: materials, diaries: [], wrongQuestions: []) }
    }

    // MARK: - 生命周期

    func applicationDidBecomeActive() {
        UIApplication.shared.applicationIconBadgeNumber = 0
        shortcutsProvider.updateShortcuts(basedOn: appSettings)
    }

    func applicationWillResignActive() {
        flushPendingChangesBeforeTerminate()
    }

    func applicationDidEnterBackground() {
        flushPendingChangesBeforeTerminate()
    }

    func handleDeepLink(_ url: URL) {
        // smartnote://tab/3 等深度链接处理
        guard url.scheme == "smartnote" else { return }
        let components = url.pathComponents.filter { $0 != "/" }
        if components.first == "tab", let tabIndex = Int(components.dropFirst().first ?? "") {
            goToSection(tabIndex)
        } else if components.first == "newMaterial" {
            showFileImporter = true
        } else if components.first == "newDiary" {
            // 打开日记编辑器
        } else if components.first == "pomodoro" {
            goToSection(IPadSection.pomodoro.rawValue)
        }
    }

    /// 跳到某个功能页。**同时**更新 iPad 与 iPhone 的导航状态。
    ///
    /// 深链、快捷指令、通知点击都走这里：iPad 直接用 `selectedTab`，
    /// iPhone 还需要把对应的底部标签切过去，否则用户点了通知仍停在别的 tab。
    func goToSection(_ section: Int) {
        selectedTab = section
        if let pad = IPadSection(rawValue: section) {
            switch pad {
            case .allMaterials, .lecture, .exam, .notes, .favorites:
                iphoneTab = .materials
            case .keyPoints, .aiChat, .smartGrading, .pomodoro,
                 .wrongQuestion, .flashCard, .whiteboard:
                iphoneTab = .study
            case .reviewPlan, .examCountdown, .todo, .habit:
                iphoneTab = .plans
            case .statistics, .p2pSocial, .relaxGame, .diary, .fileCrypto,
                 .whiteNoise, .answerBook, .anniversary, .calculator,
                 .duplicateScanner, .history:
                iphoneTab = .tools
            }
        }
    }

    func handleHandoff(_ userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        handleDeepLink(url)
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
        // 文件名必须是不含路径分隔符的**安全名**。
        //
        // 原先这里用 `DateFormatter.localizedString(from:dateStyle:.short,
        // timeStyle:.short)`，在 zh-Hans 下产出的是 `2026/10/7 12:36` ——
        // **含斜杠**。`appendingPathComponent` 会把它当成多级路径，
        // 于是最终路径变成 `Materials/扫描文档_2026/10/7 12:36.pdf`，
        // 而那些中间目录并不存在，`data.write(to:)` 直接抛
        // "No such file or directory"，扫描结果保存必然失败。
        //
        // 这里改用固定格式 + en_US_POSIX，且不依赖当前区域设置。
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let fileName = "扫描文档_\(formatter.string(from: Date())).pdf"

        let directory = storageService.getMaterialsDirectory()
        // 兜底：目录可能因权限或清理而消失，先确保存在再写。
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            await MainActor.run {
                errorMessage = "无法创建资料目录：\(error.localizedDescription)"
                showError = true
                hapticFeedbackService.error()
            }
            return
        }

        let url = directory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
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
        // 两个「早退」分支都必须先把 `isProcessingOCR` 置 false，
        // 否则 `OCRProgressView` 的 `.onChange(of: isProcessingOCR)`
        // 永远不会触发 dismiss，弹窗会一直卡在转圈状态。
        // 原先这里是裸 `guard ... else { return }`，直接 return 掉，
        // 表现就是「点了 OCR 一直转圈、关不掉」。
        guard let fileURL = material.localURL else {
            isProcessingOCR = false
            errorMessage = "这份资料没有关联文件，无法识别。请先导入原始文件。"
            showError = true
            hapticFeedbackService.error()
            return
        }
        isProcessingOCR = true
        Task {
            let text = await ocrService.recognizeText(from: fileURL)
            await MainActor.run {
                if let index = materials.firstIndex(where: { $0.id == material.id }) {
                    materials[index].extractedText = text
                    storageService.saveMaterials(materials)
                }
                isProcessingOCR = false
                // 识别失败时必须给出反馈：原先 text 为 nil 时一切照旧，
                // 界面毫无变化，用户只能以为「点了没反应」。
                if let text, !text.isEmpty {
                    hapticFeedbackService.success()
                } else {
                    errorMessage = material.type == .pdf
                        ? "未能从这份 PDF 中提取到文字。扫描版 PDF 可尝试先另存为图片后再导入。"
                        : "未能识别出文字。请确认文件是清晰的图片。"
                    showError = true
                    hapticFeedbackService.error()
                }
            }
        }
    }

    func extractKeywords(for material: StudyMaterial) {
        let text = material.extractedText ?? material.content
        // 同上：早退时也要复位标志，否则弹窗关不掉。
        guard !text.isEmpty else {
            isExtractingKeywords = false
            errorMessage = "这份资料还没有可用文字，无法提取关键词。请先做 OCR 识别或手动填写内容。"
            showError = true
            hapticFeedbackService.error()
            return
        }
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
                if keywords.isEmpty {
                    errorMessage = "没有提取到关键词，文字可能太短。"
                    showError = true
                    hapticFeedbackService.error()
                } else {
                    hapticFeedbackService.success()
                }
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