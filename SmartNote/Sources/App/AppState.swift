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
    /// BlessingService 同样是嵌套 ObservableObject。它的 `isNationalDayPeriod` 直接被
    /// ContentView 的 body 读取时不会触发重算（视图只 observe AppState），
    /// 表现为国庆期间祝福条时有时无。这里由 AppState 转发为 @Published 快照。
    @Published private(set) var isNationalDayPeriod: Bool = false
    /// 祝福条是否应显示：节庆主题，或处于国庆期间。
    var shouldShowBlessingBar: Bool {
        theme.isFestive || isNationalDayPeriod
    }
    
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
    /// 订阅 appSettings 的 objectWillChange 并转发为 AppState 的变更。
    /// appSettings 被整体替换时必须重绑（见 rebindAppSettingsObservation）。
    private var appSettingsCancellable: AnyCancellable?

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
        self.isNationalDayPeriod = blessingService.isNationalDayPeriod
        self.historyService = HistoryService(storageService: probeStorage)
        self.appSettings = settings
        self.activeThemeID = settings.themeID
        self.activeDarkModePreference = settings.darkModePreference
        self.lastStartupMigration = migrationResult
        loadSavedData()
        prepareBackgroundImage()

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
        // 把 AppSettings 自身的变更转发为 AppState 的变更。
        //
        // AppSettings 是嵌套 ObservableObject：改 appSettings.backgroundImageName
        // 只会触发 AppSettings.objectWillChange，不会触发 AppState.objectWillChange，
        // 于是所有 `@EnvironmentObject var appState: AppState` 的视图都不重渲染。
        // 表现就是「改了背景图要重启才生效」。
        // 之前 themeID / 明暗模式是靠手工再写一份顶层 @Published 快照绕过的，
        // 但背景图这类字段没有对应的顶层属性，只能在这里统一转发。
        // 把 AppSettings 自身的变更转发为 AppState 的变更（详见 rebindAppSettingsObservation）
        rebindAppSettingsObservation()
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
    
    /// 把 `appSettings` 的 `objectWillChange` 转发为 `AppState` 的 `objectWillChange`。
    ///
    /// `AppSettings` 是嵌套 `ObservableObject`：改 `appSettings.backgroundImageName`
    /// 只会触发 `AppSettings.objectWillChange`，不会触发 `AppState.objectWillChange`，
    /// 于是所有 `@EnvironmentObject var appState: AppState` 的视图都不重渲染——
    /// 表现是「改了背景图要重启才生效」。
    /// 主题与明暗模式之前是靠手工再写一份顶层 `@Published` 快照绕过的，
    /// 但背景图这类字段没有对应的顶层属性，只能在这里统一转发。
    ///
    /// **每次整体替换 `appSettings` 后都必须重新调用**，
    /// 否则订阅会留在已被丢弃的旧对象上，变更不再转发。
    private func rebindAppSettingsObservation() {
        appSettingsCancellable = appSettings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
    }

    func refreshSettings() {
        let currentExamCountdowns = examCountdowns
        let loadedSettings = storageService.loadSettings()
        self.appSettings = loadedSettings
        rebindAppSettingsObservation()
        self.activeThemeID = loadedSettings.themeID
        self.activeDarkModePreference = loadedSettings.darkModePreference
        // appSettings 的倒计时字段只作为内存镜像，不从旧磁盘快照反向覆盖。
        self.appSettings.examCountdowns = currentExamCountdowns
    }

    /// 切换主题。节庆主题会强制锁定到它自带的背景图。
    ///
    /// 写盘收敛到这一处：`applyThemeBackgroundLock` 只改内存状态，不自己保存，
    /// 否则一次切主题会连续写盘三次。
    func setTheme(_ themeID: AppSettings.ThemeID) {
        guard activeThemeID != themeID else { return }
        appSettings.themeID = themeID
        activeThemeID = themeID
        applyThemeBackgroundLock(for: themeID)
        storageService.saveSettings(appSettings)
    }

    /// 节庆主题锁定背景：强制启用背景并指向自带素材，关闭随机轮换。
    /// 切回经典主题时恢复用户此前的随机/指定设置。
    /// 只修改内存状态，落盘由调用方负责。
    private func applyThemeBackgroundLock(for themeID: AppSettings.ThemeID) {
        let target = AppTheme.theme(for: themeID)
        guard let bundled = target.bundledBackgroundName else {
            // 经典主题：解除锁定，用户设置继续生效。
            appSettings.backgroundImageActiveName = appSettings.backgroundImageName
            return
        }
        // 素材被删除过（清空数据或手动删文件）时先恢复。
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

    /// 内置素材恢复失败时提示用户；成功或未触发时为 nil。
    @Published private(set) var restorationFailedBundledImage: String?

    /// 许愿窗口的待打开请求。由 Siri / Shortcuts 置位，持有 `openWindow` 的视图消费。
    @Published var wishWindowRequestToken: Int = 0

    /// 置位一次「打开许愿窗口」请求。重复调用会推进 token，保证每次都能触发。
    func deliverWishWindowRequest() {
        wishWindowRequestToken &+= 1
    }

    // MARK: - 背景图片库

    /// 启动时处理背景图：先补回缺失的内置素材，再按主题决定是否锁定。
    func prepareBackgroundImage() {
        // 内置素材被删除后自动从应用包恢复，主题才不会因为缺图而失效。
        storageService.restoreBundledBackgroundsIfMissing()
        let bundled = theme.bundledBackgroundName
        if let bundled {
            // 启动时若停留在节庆主题，继续保持锁定状态。
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
                    // pickRandomBackgroundImage 内部已落盘
                    pickRandomBackgroundImage(excluding: appSettings.backgroundImageActiveName)
                    return
                } else if appSettings.backgroundImageActiveName == nil {
                    appSettings.backgroundImageActiveName = appSettings.backgroundImageName
                }
            }
        }
        // 主题锁定与素材恢复的结论必须落盘，否则下次启动读到的仍是旧值。
        // 走随机分支时上面已 return，不会重复写。
        storageService.saveSettings(appSettings)
    }

    /// 丢弃已不存在于磁盘的条目，并补入磁盘上新增的图片。
    /// 内置素材始终保留在列表中，避免被磁盘清理误伤。
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

    /// 是否处于主题锁定状态：节庆主题下背景被强制占用。
    var isBackgroundLockedByTheme: Bool { theme.bundledBackgroundName != nil }

    /// 当前锁定背景的主题素材名。
    var lockedBundledBackgroundName: String? { theme.bundledBackgroundName }

    func clearRestorationFailure() { restorationFailedBundledImage = nil }

    /// 加入图片库。节庆主题锁定期间不生效。
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

    /// 指定模式下锁定某一张；随机模式下只是把它设为当前显示。
    /// 节庆主题锁定期间无效。
    func selectBackgroundImage(_ fileName: String) {
        guard !isBackgroundLockedByTheme else { return }
        appSettings.backgroundImageName = fileName
        appSettings.backgroundImageActiveName = fileName
        storageService.saveSettings(appSettings)
    }

    /// 内置素材受保护，不可删除。
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

    /// 清空用户图片库；内置素材始终保留，并在缺失时自动恢复。
    func clearUserBackgroundLibrary() {
        for name in appSettings.backgroundImageLibrary
        where !StorageService.isBundledBackground(name) {
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
            let userImages = appSettings.backgroundImageLibrary
                .filter { !StorageService.isBundledBackground($0) }
            appSettings.backgroundImageName = userImages.first
            appSettings.backgroundImageActiveName = userImages.first
            appSettings.backgroundImageRandomEnabled = false
            if userImages.isEmpty {
                appSettings.backgroundImageEnabled = false
            }
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
        if enabled {
            pickRandomBackgroundImage(excluding: appSettings.backgroundImageActiveName)
        } else {
            appSettings.backgroundImageActiveName = appSettings.backgroundImageName
        }
        // pickRandomBackgroundImage 内已落盘，这里不再重复写。
    }

    /// 从图片库随机挑一张，尽量避开 exclude 指定的那张。
    /// 节庆主题锁定期间无效；只从用户图片中随机，不动内置素材。
    func pickRandomBackgroundImage(excluding exclude: String? = nil) {
        guard !isBackgroundLockedByTheme else { return }
        syncBackgroundImageLibrary()
        let userLibrary = appSettings.backgroundImageLibrary
            .filter { !StorageService.isBundledBackground($0) }
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

    /// 恢复备份前把内存中尚未落盘的数据写回磁盘。
    ///
    /// 待办、习惯、日记、许愿、纪念日等由各自 Service 在每次写操作后立即落盘，
    /// 这里不重复处理；需要兜底的是 AppState 自己持有、依赖视图侧显式保存的数组，
    /// 以及设置与历史阅读进度。
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
        isNationalDayPeriod = blessingService.isNationalDayPeriod
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
