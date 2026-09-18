import Foundation

class StorageService {
    private let fileManager = FileManager.default
    private let appSupportDirectory: URL

    /// 当前 settings schema 版本。每次 storage JSON 字段有结构变化时递增。
    /// 启动时若旧 settings.json < 此值，会先备份再迁移字段。
    static let currentSchemaVersion: Int = 2

    /// 应用支持目录 URL，供 BackupService 与「存储 → 备份与恢复」面板使用
    var appSupportURL: URL { appSupportDirectory }

    private var materialsFileURL: URL {
        appSupportDirectory.appendingPathComponent("materials.json")
    }
    
    private var reviewPlansFileURL: URL {
        appSupportDirectory.appendingPathComponent("reviewPlans.json")
    }
    
    private var settingsFileURL: URL {
        appSupportDirectory.appendingPathComponent("settings.json")
    }
    
    private var learningProfileFileURL: URL {
        appSupportDirectory.appendingPathComponent("learningProfile.json")
    }
    
    private var pdfAnnotationsFileURL: URL {
        appSupportDirectory.appendingPathComponent("pdfAnnotations.json")
    }
    
    private var studySessionsFileURL: URL {
        appSupportDirectory.appendingPathComponent("studySessions.json")
    }
    
    private var wrongQuestionsFileURL: URL {
        appSupportDirectory.appendingPathComponent("wrongQuestions.json")
    }
    
    private var flashCardsFileURL: URL {
        appSupportDirectory.appendingPathComponent("flashCards.json")
    }
    
    private var backgroundImagesDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("BackgroundImages", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    init() {
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        appSupportDirectory = paths.first!.appendingPathComponent("SmartNote")
        
        if !fileManager.fileExists(atPath: appSupportDirectory.path) {
            try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        }
    }
    
    func saveMaterials(_ materials: [StudyMaterial]) {
        save(materials, to: materialsFileURL)
    }

    func loadMaterials() -> [StudyMaterial] {
        load(from: materialsFileURL) ?? []
    }

    // MARK: - 启动期 schema 迁移

    /// 启动时调用：检测 settings.json 缺字段或 schemaVersion 偏低，先静默备份再升级。
    /// - Returns: 一个描述迁移结果的对象，供启动 banner / 日志展示
    @discardableResult
    func runStartupMigration() -> StartupMigrationResult {
        let onDisk = loadSettings()
        var working = onDisk

        let now = Date()
        let backupService = BackupService(sourceRoot: appSupportDirectory)
        var createdBackupURL: URL?
        var backupError: Error?

        // 1. 仅当检测到"低于当前 schema"才备份一次
        if working.schemaVersion < Self.currentSchemaVersion {
            do {
                createdBackupURL = try backupService.makeBackup(
                    label: "pre-migration-v\(working.schemaVersion)-to-v\(Self.currentSchemaVersion)"
                )
            } catch {
                backupError = error
            }
        }

        // 2. 强制把 schemaVersion 写到当前值；decodeIfPresent 已为所有新字段补默认
        //    （P0 阶段本身没有 destructive 字段变更；未来字段重命名时这一步改成显式 transform）
        working.schemaVersion = Self.currentSchemaVersion
        if working.lastMigrationDate == nil {
            working.lastMigrationDate = now
        }
        // 每次启动都更新 lastMigrationCheckedAt，便于支持面板显示「上次迁移时间」
        working.lastMigrationCheckedAt = now

        // 3. 仅在真有变动时持久化（避免每次启动都写盘）
        if working != onDisk {
            saveSettings(working)
        }

        return StartupMigrationResult(
            fromVersion: onDisk.schemaVersion,
            toVersion: Self.currentSchemaVersion,
            backupURL: createdBackupURL,
            backupError: backupError,
            checkedAt: now
        )
    }

    // MARK: - Review Plans
    
    func saveReviewPlans(_ plans: [ReviewPlan]) {
        save(plans, to: reviewPlansFileURL)
    }
    
    func loadReviewPlans() -> [ReviewPlan] {
        load(from: reviewPlansFileURL) ?? []
    }
    
    func saveSettings(_ settings: AppSettings) {
        save(settings, to: settingsFileURL)
    }
    
    func loadSettings() -> AppSettings {
        load(from: settingsFileURL) ?? AppSettings()
    }
    
    func saveLearningProfile(_ profile: UserLearningProfile) {
        save(profile, to: learningProfileFileURL)
    }
    
    func loadLearningProfile() -> UserLearningProfile {
        load(from: learningProfileFileURL) ?? UserLearningProfile()
    }
    
    func savePDFAnnotations(_ annotations: [UUID: PDFAnnotationsData]) {
        var simplifiedAnnotations: [String: PDFAnnotationsData] = [:]
        for (key, value) in annotations {
            simplifiedAnnotations[key.uuidString] = value
        }
        save(simplifiedAnnotations, to: pdfAnnotationsFileURL)
    }
    
    func loadPDFAnnotations() -> [UUID: PDFAnnotationsData] {
        let loaded: [String: PDFAnnotationsData]? = load(from: pdfAnnotationsFileURL)
        guard let loaded = loaded else { return [:] }
        
        var result: [UUID: PDFAnnotationsData] = [:]
        for (key, value) in loaded {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = value
            }
        }
        return result
    }
    
    func saveStudySessions(_ sessions: [StudySession]) {
        save(sessions, to: studySessionsFileURL)
    }
    
    func loadStudySessions() -> [StudySession] {
        return load(from: studySessionsFileURL) ?? []
    }
    
    func saveWrongQuestions(_ questions: [WrongQuestion]) {
        save(questions, to: wrongQuestionsFileURL)
    }
    
    func loadWrongQuestions() -> [WrongQuestion] {
        return load(from: wrongQuestionsFileURL) ?? []
    }
    
    func saveFlashCards(_ cards: [FlashCard]) {
        save(cards, to: flashCardsFileURL)
    }
    
    func loadFlashCards() -> [FlashCard] {
        return load(from: flashCardsFileURL) ?? []
    }
    
    private var diaryEntriesFileURL: URL {
        appSupportDirectory.appendingPathComponent("diaryEntries.json")
    }
    
    private var diaryCategoriesFileURL: URL {
        appSupportDirectory.appendingPathComponent("diaryCategories.json")
    }
    
    func saveDiaryEntries(_ entries: [DiaryEntry]) {
        save(entries, to: diaryEntriesFileURL)
    }
    
    func loadDiaryEntries() -> [DiaryEntry] {
        return load(from: diaryEntriesFileURL) ?? []
    }
    
    func saveDiaryCategories(_ categories: [DiaryCategory]) {
        save(categories, to: diaryCategoriesFileURL)
    }
    
    func loadDiaryCategories() -> [DiaryCategory] {
        return load(from: diaryCategoriesFileURL) ?? []
    }
    
    private var p2pIdentityFileURL: URL {
        appSupportDirectory.appendingPathComponent("p2pIdentity.json")
    }
    
    private var p2pFriendsFileURL: URL {
        appSupportDirectory.appendingPathComponent("p2pFriends.json")
    }
    
    private var p2pBlackListFileURL: URL {
        appSupportDirectory.appendingPathComponent("p2pBlackList.json")
    }
    
    func saveP2PIdentity(_ identity: P2PUserIdentity) {
        save(identity, to: p2pIdentityFileURL)
    }
    
    func loadP2PIdentity() -> P2PUserIdentity? {
        return load(from: p2pIdentityFileURL)
    }
    
    func deleteP2PIdentity() {
        try? FileManager.default.removeItem(at: p2pIdentityFileURL)
    }
    
    func saveP2PFriends(_ friends: [P2PFriend]) {
        save(friends, to: p2pFriendsFileURL)
    }
    
    func loadP2PFriends() -> [P2PFriend] {
        return load(from: p2pFriendsFileURL) ?? []
    }
    
    func deleteAllP2PFriends() {
        try? FileManager.default.removeItem(at: p2pFriendsFileURL)
    }
    
    func saveP2PBlackList(_ blackList: [P2PBlackIP]) {
        save(blackList, to: p2pBlackListFileURL)
    }
    
    func loadP2PBlackList() -> [P2PBlackIP] {
        return load(from: p2pBlackListFileURL) ?? []
    }
    
    func deleteP2PBlackList() {
        try? FileManager.default.removeItem(at: p2pBlackListFileURL)
    }
    
    private var p2pGroupsFileURL: URL {
        appSupportDirectory.appendingPathComponent("p2pGroups.json")
    }
    
    var p2pGroupMessagesFileURL: URL {
        appSupportDirectory.appendingPathComponent("p2pGroupMessages.enc")
    }
    
    var p2pMessagesFileURL: URL {
        appSupportDirectory.appendingPathComponent("p2pMessages.enc")
    }
    
    func saveP2PGroups(_ groups: [P2PGroup]) {
        save(groups, to: p2pGroupsFileURL)
    }
    
    func loadP2PGroups() -> [P2PGroup] {
        load(from: p2pGroupsFileURL) ?? []
    }
    
    func deleteAllP2PGroups() {
        try? FileManager.default.removeItem(at: p2pGroupsFileURL)
        try? FileManager.default.removeItem(at: p2pGroupMessagesFileURL)
    }
    
    func deleteP2PMessages(for friendID: UUID) {
        try? FileManager.default.removeItem(at: p2pMessagesFileURL)
    }

    func deleteP2PGroupMessages(for groupID: UUID) {
        try? FileManager.default.removeItem(at: p2pGroupMessagesFileURL)
    }
    
    private var todoItemsFileURL: URL {
        appSupportDirectory.appendingPathComponent("todoItems.json")
    }

    private var habitsFileURL: URL {
        appSupportDirectory.appendingPathComponent("habits.json")
    }
    
    private var todoCategoriesFileURL: URL {
        appSupportDirectory.appendingPathComponent("todoCategories.json")
    }
    
    func saveTodoItems(_ items: [TodoItem]) {
        save(items, to: todoItemsFileURL)
    }
    
    func loadTodoItems() -> [TodoItem] {
        return load(from: todoItemsFileURL) ?? []
    }
    
    func saveTodoCategories(_ categories: [TodoCategory]) {
        save(categories, to: todoCategoriesFileURL)
    }
    
    func loadTodoCategories() -> [TodoCategory] {
        return load(from: todoCategoriesFileURL) ?? []
    }

    func saveHabits(_ habits: [Habit]) {
        save(habits, to: habitsFileURL)
    }

    func loadHabits() -> [Habit] {
        return load(from: habitsFileURL) ?? []
    }
    
    // MARK: - Background Images
    
    func saveBackgroundImage(_ imageData: Data, fileName: String) -> URL? {
        let destinationURL = backgroundImagesDirectory.appendingPathComponent(fileName)
        do {
            try imageData.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            print("Error saving background image: \(error)")
            return nil
        }
    }
    
    func loadBackgroundImage(named fileName: String) -> Data? {
        let fileURL = backgroundImagesDirectory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try? Data(contentsOf: fileURL)
    }
    
    func deleteBackgroundImage(named fileName: String) {
        let fileURL = backgroundImagesDirectory.appendingPathComponent(fileName)
        try? fileManager.removeItem(at: fileURL)
    }
    
    func listBackgroundImages() -> [String] {
        do {
            let files = try fileManager.contentsOfDirectory(atPath: backgroundImagesDirectory.path)
            return files.filter { !$0.hasPrefix(".") }
        } catch {
            print("Error listing background images: \(error)")
            return []
        }
    }
    
    func getBackgroundImagesDirectory() -> URL {
        return backgroundImagesDirectory
    }
    
    func getBackgroundImageURL(named fileName: String) -> URL {
        return backgroundImagesDirectory.appendingPathComponent(fileName)
    }
    
    private func save<T: Encodable>(_ object: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(object)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Error saving to \(url): \(error)")
        }
    }
    
    private func load<T: Decodable>(from url: URL) -> T? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            print("Error loading from \(url): \(error)")
            return nil
        }
    }
    
    func clearAllData() {
        try? fileManager.removeItem(at: materialsFileURL)
        try? fileManager.removeItem(at: reviewPlansFileURL)
        try? fileManager.removeItem(at: settingsFileURL)
    }
    
    func exportData() -> Data? {
        let exportData = ExportData(
            materials: loadMaterials(),
            reviewPlans: loadReviewPlans(),
            exportedAt: Date()
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        return try? encoder.encode(exportData)
    }
    
    func getStorageSize() -> Int64 {
        var totalSize: Int64 = 0
        
        let files = [materialsFileURL, reviewPlansFileURL, settingsFileURL]
        
        for file in files {
            if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
               let size = attributes[.size] as? Int64 {
                totalSize += size
            }
        }
        
        return totalSize
    }
}

/// 启动迁移结果。仅在 schema 升级或用户首次启动时才有实际内容。
struct StartupMigrationResult {
    let fromVersion: Int
    let toVersion: Int
    let backupURL: URL?
    let backupError: Error?
    let checkedAt: Date

    var didUpgrade: Bool { fromVersion < toVersion }
    var didBackup: Bool { backupURL != nil }
}

class AppSettings: ObservableObject, Codable, Equatable {
    /// 持久化 schema 版本号。每当 settings.json 字段有破坏性变更时递增。
    /// 由 StorageService.runStartupMigration() 管理；UI 不应直接修改。
    @Published var schemaVersion: Int = StorageService.currentSchemaVersion
    @Published var lastMigrationDate: Date? = nil
    @Published var lastMigrationCheckedAt: Date? = nil

    @Published var autoScanDirectories: Bool = true
    @Published var scanPaths: [String] = []
    @Published var darkModePreference: DarkModePreference = .system
    @Published var calendarIntegrationEnabled: Bool = true
    @Published var reminderEnabled: Bool = true
    @Published var defaultStudyMinutes: Int = 30
    @Published var showFileExtensions: Bool = true
    @Published var llmConfiguration: LLMConfiguration = LLMConfiguration()
    @Published var pomodoroWorkDuration: Int = 25
    @Published var pomodoroBreakDuration: Int = 5
    @Published var examCountdowns: [ExamCountdown] = []
    @Published var autoUpdateEnabled: Bool = false
    @Published var updateChannel: UpdateChannel = .latest
    @Published var updateRepoOwner: String = "XiJian-Development-Group"
    @Published var updateRepoName: String = "SmartNote"
    @Published var updateCheckIntervalHours: Int = 24
    @Published var lastUpdateCheckDate: Date? = nil
    @Published var lastFoundReleaseName: String? = nil
    @Published var p2pBackgroundEnabled: Bool = false

    // Background image settings
    @Published var backgroundImageEnabled: Bool = false
    @Published var backgroundImageName: String? = nil
    @Published var backgroundBlurEnabled: Bool = true
    @Published var backgroundBlurRadius: Double = 20.0
    @Published var backgroundOpacity: Double = 0.3

    static func == (lhs: AppSettings, rhs: AppSettings) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion &&
        lhs.lastMigrationDate == rhs.lastMigrationDate &&
        lhs.lastMigrationCheckedAt == rhs.lastMigrationCheckedAt &&
        lhs.autoScanDirectories == rhs.autoScanDirectories &&
        lhs.scanPaths == rhs.scanPaths &&
        lhs.darkModePreference == rhs.darkModePreference &&
        lhs.calendarIntegrationEnabled == rhs.calendarIntegrationEnabled &&
        lhs.reminderEnabled == rhs.reminderEnabled &&
        lhs.defaultStudyMinutes == rhs.defaultStudyMinutes &&
        lhs.showFileExtensions == rhs.showFileExtensions &&
        lhs.llmConfiguration == rhs.llmConfiguration &&
        lhs.pomodoroWorkDuration == rhs.pomodoroWorkDuration &&
        lhs.pomodoroBreakDuration == rhs.pomodoroBreakDuration &&
        lhs.examCountdowns == rhs.examCountdowns &&
        lhs.autoUpdateEnabled == rhs.autoUpdateEnabled &&
        lhs.updateChannel == rhs.updateChannel &&
        lhs.updateRepoOwner == rhs.updateRepoOwner &&
        lhs.updateRepoName == rhs.updateRepoName &&
        lhs.updateCheckIntervalHours == rhs.updateCheckIntervalHours &&
        lhs.lastUpdateCheckDate == rhs.lastUpdateCheckDate &&
        lhs.lastFoundReleaseName == rhs.lastFoundReleaseName &&
        lhs.p2pBackgroundEnabled == rhs.p2pBackgroundEnabled &&
        lhs.backgroundImageEnabled == rhs.backgroundImageEnabled &&
        lhs.backgroundImageName == rhs.backgroundImageName &&
        lhs.backgroundBlurEnabled == rhs.backgroundBlurEnabled &&
        lhs.backgroundBlurRadius == rhs.backgroundBlurRadius &&
        lhs.backgroundOpacity == rhs.backgroundOpacity
    }
    
    enum DarkModePreference: String, Codable, Equatable {
        case system
        case light
        case dark
    }

    enum UpdateChannel: String, Codable, Equatable {
        case latest
        case prerelease
    }
    
    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lastMigrationDate
        case lastMigrationCheckedAt
        case autoScanDirectories
        case scanPaths
        case darkModePreference
        case calendarIntegrationEnabled
        case reminderEnabled
        case defaultStudyMinutes
        case showFileExtensions
        case llmConfiguration
        case pomodoroWorkDuration
        case pomodoroBreakDuration
        case examCountdowns
        case autoUpdateEnabled
        case updateChannel
        case updateRepoOwner
        case updateRepoName
        case updateCheckIntervalHours
        case lastUpdateCheckDate
        case lastFoundReleaseName
        case backgroundImageEnabled
        case backgroundImageName
        case backgroundBlurEnabled
        case backgroundBlurRadius
        case backgroundOpacity
    }

    init() {
        schemaVersion = StorageService.currentSchemaVersion
        lastMigrationDate = nil
        lastMigrationCheckedAt = nil
        autoScanDirectories = true
        scanPaths = []
        darkModePreference = .system
        calendarIntegrationEnabled = true
        reminderEnabled = true
        defaultStudyMinutes = 30
        showFileExtensions = true
        llmConfiguration = LLMConfiguration()
        pomodoroWorkDuration = 25
        pomodoroBreakDuration = 5
        examCountdowns = []
        autoUpdateEnabled = false
        updateChannel = .latest
        backgroundImageEnabled = false
        backgroundImageName = nil
        backgroundBlurEnabled = true
        backgroundBlurRadius = 20.0
        backgroundOpacity = 0.3
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // 老版本 settings.json 没有 schemaVersion → 视为 v1
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lastMigrationDate = try container.decodeIfPresent(Date.self, forKey: .lastMigrationDate)
        lastMigrationCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastMigrationCheckedAt)
        autoScanDirectories = try container.decodeIfPresent(Bool.self, forKey: .autoScanDirectories) ?? true
        scanPaths = try container.decodeIfPresent([String].self, forKey: .scanPaths) ?? []
        darkModePreference = try container.decodeIfPresent(DarkModePreference.self, forKey: .darkModePreference) ?? .system
        calendarIntegrationEnabled = try container.decodeIfPresent(Bool.self, forKey: .calendarIntegrationEnabled) ?? true
        reminderEnabled = try container.decodeIfPresent(Bool.self, forKey: .reminderEnabled) ?? true
        defaultStudyMinutes = try container.decodeIfPresent(Int.self, forKey: .defaultStudyMinutes) ?? 30
        showFileExtensions = try container.decodeIfPresent(Bool.self, forKey: .showFileExtensions) ?? true
        llmConfiguration = try container.decodeIfPresent(LLMConfiguration.self, forKey: .llmConfiguration) ?? LLMConfiguration()
        pomodoroWorkDuration = try container.decodeIfPresent(Int.self, forKey: .pomodoroWorkDuration) ?? 25
        pomodoroBreakDuration = try container.decodeIfPresent(Int.self, forKey: .pomodoroBreakDuration) ?? 5
        examCountdowns = try container.decodeIfPresent([ExamCountdown].self, forKey: .examCountdowns) ?? []
        autoUpdateEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? false
        updateChannel = try container.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel) ?? .latest
        updateRepoOwner = try container.decodeIfPresent(String.self, forKey: .updateRepoOwner) ?? "XiJian-Development-Group"
        updateRepoName = try container.decodeIfPresent(String.self, forKey: .updateRepoName) ?? "SmartNote"
        updateCheckIntervalHours = try container.decodeIfPresent(Int.self, forKey: .updateCheckIntervalHours) ?? 24
        lastUpdateCheckDate = try container.decodeIfPresent(Date.self, forKey: .lastUpdateCheckDate)
        lastFoundReleaseName = try container.decodeIfPresent(String.self, forKey: .lastFoundReleaseName)
        backgroundImageEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundImageEnabled) ?? false
        backgroundImageName = try container.decodeIfPresent(String.self, forKey: .backgroundImageName)
        backgroundBlurEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundBlurEnabled) ?? true
        backgroundBlurRadius = try container.decodeIfPresent(Double.self, forKey: .backgroundBlurRadius) ?? 20.0
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0.3
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(lastMigrationDate, forKey: .lastMigrationDate)
        try container.encodeIfPresent(lastMigrationCheckedAt, forKey: .lastMigrationCheckedAt)
        try container.encode(autoScanDirectories, forKey: .autoScanDirectories)
        try container.encode(scanPaths, forKey: .scanPaths)
        try container.encode(darkModePreference, forKey: .darkModePreference)
        try container.encode(calendarIntegrationEnabled, forKey: .calendarIntegrationEnabled)
        try container.encode(reminderEnabled, forKey: .reminderEnabled)
        try container.encode(defaultStudyMinutes, forKey: .defaultStudyMinutes)
        try container.encode(showFileExtensions, forKey: .showFileExtensions)
        try container.encode(llmConfiguration, forKey: .llmConfiguration)
        try container.encode(pomodoroWorkDuration, forKey: .pomodoroWorkDuration)
        try container.encode(pomodoroBreakDuration, forKey: .pomodoroBreakDuration)
        try container.encode(examCountdowns, forKey: .examCountdowns)
        try container.encode(autoUpdateEnabled, forKey: .autoUpdateEnabled)
        try container.encode(updateChannel, forKey: .updateChannel)
        try container.encode(updateRepoOwner, forKey: .updateRepoOwner)
        try container.encode(updateRepoName, forKey: .updateRepoName)
        try container.encode(updateCheckIntervalHours, forKey: .updateCheckIntervalHours)
        try container.encodeIfPresent(lastUpdateCheckDate, forKey: .lastUpdateCheckDate)
        try container.encodeIfPresent(lastFoundReleaseName, forKey: .lastFoundReleaseName)
        try container.encode(backgroundImageEnabled, forKey: .backgroundImageEnabled)
        try container.encodeIfPresent(backgroundImageName, forKey: .backgroundImageName)
        try container.encode(backgroundBlurEnabled, forKey: .backgroundBlurEnabled)
        try container.encode(backgroundBlurRadius, forKey: .backgroundBlurRadius)
        try container.encode(backgroundOpacity, forKey: .backgroundOpacity)
    }
}

struct ExportData: Codable {
    let materials: [StudyMaterial]
    let reviewPlans: [ReviewPlan]
    let exportedAt: Date
}
