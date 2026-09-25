import Foundation

extension Notification.Name {
    /// 数据文件读取或解码失败时广播的通知名。
    static let storageIntegrityIssue = Notification.Name("storageIntegrityIssue")
    /// 清除所有受管数据完成后广播的通知名。
    static let storageDidClearAllData = Notification.Name("storageDidClearAllData")
    /// settings.json 或钥匙串持久化失败时广播的通知名。
    static let storageSettingsPersistenceIssue = Notification.Name("storageSettingsPersistenceIssue")
}

/// 一次数据完整性问题的内存记录。关闭横幅只清理内存记录，不写入 settings.json。
struct StorageIntegrityIssue: Identifiable, Equatable {
    let id: UUID
    let fileURL: URL
    let message: String
    let timestamp: Date

    init(id: UUID = UUID(), fileURL: URL, message: String, timestamp: Date = Date()) {
        self.id = id
        self.fileURL = fileURL
        self.message = message
        self.timestamp = timestamp
    }
}

class StorageService {
    private let fileManager = FileManager.default
    private let appSupportDirectory: URL
    private let keychainService: KeychainService
    /// 旧 settings 仍含明文 key 且尚未成功剥离时，禁止启动迁移再复制一份到备份。
    private var legacyAPIKeyMigrationPending = false

    /// 启动时可能早于 ContentView 创建，因此保留一份仅在内存中的问题记录。
    private static let integrityIssuesLock = NSLock()
    private static var recordedIntegrityIssues: [StorageIntegrityIssue] = []

    /// 当前 settings schema 版本。每次 storage JSON 字段有结构变化时递增。
    /// 启动时若旧 settings.json < 此值，会先备份再迁移字段。
    static let currentSchemaVersion: Int = 2

    /// 供 ContentView 在订阅通知前补显示启动期已经发现的问题。
    static var integrityIssues: [StorageIntegrityIssue] {
        integrityIssuesLock.lock()
        defer { integrityIssuesLock.unlock() }
        return recordedIntegrityIssues.sorted { $0.timestamp < $1.timestamp }
    }

    /// 用户关闭横幅时调用；只在内存中生效，不修改任何磁盘设置。
    static func dismissIntegrityIssues() {
        integrityIssuesLock.lock()
        recordedIntegrityIssues.removeAll()
        integrityIssuesLock.unlock()
    }

    /// settings 持久化错误只保留在内存中，UI 通过属性或通知展示。
    /// 这样不会把错误详情或任何凭据写回 settings.json。
    private static let settingsPersistenceLock = NSLock()
    private static var recordedSettingsPersistenceError: String?

    static var settingsPersistenceError: String? {
        settingsPersistenceLock.lock()
        defer { settingsPersistenceLock.unlock() }
        return recordedSettingsPersistenceError
    }

    private static func reportSettingsPersistenceIssue(_ message: String) {
        settingsPersistenceLock.lock()
        let shouldPost = recordedSettingsPersistenceError != message
        recordedSettingsPersistenceError = message
        settingsPersistenceLock.unlock()

        guard shouldPost else { return }
        NotificationCenter.default.post(
            name: .storageSettingsPersistenceIssue,
            object: nil,
            userInfo: ["message": message]
        )
    }

    private static func clearSettingsPersistenceIssue() {
        settingsPersistenceLock.lock()
        recordedSettingsPersistenceError = nil
        settingsPersistenceLock.unlock()
    }

    /// 应用支持目录 URL，供 BackupService 与「存储 → 备份与恢复」面板使用
    var appSupportURL: URL { appSupportDirectory }

    /// 所有受管数据位置的唯一清单。统计、清理和备份路径解析都从这里复用。
    private enum ManagedDataPath: CaseIterable {
        case materialsJSON
        case reviewPlansJSON
        case settingsJSON
        case examCountdownsJSON
        case historyProgressJSON
        case learningProfileJSON
        case pdfAnnotationsJSON
        case studySessionsJSON
        case wrongQuestionsJSON
        case flashCardsJSON
        case diaryEntriesJSON
        case diaryCategoriesJSON
        case p2pIdentityJSON
        case p2pFriendsJSON
        case p2pBlackListJSON
        case p2pGroupsJSON
        case p2pGroupMessages
        case p2pMessages
        case todoItemsJSON
        case habitsJSON
        case todoCategoriesJSON
        case whiteboardsJSON
        case wishesJSON
        case anniversariesJSON
        case materialsDirectory
        case diaryImagesDirectory
        case quickNotesDirectory
        case backgroundImagesDirectory
        case ambientSoundsDirectory
        case pdfExportsDirectory
        case backupDirectory
        case legacyBackupDirectory

        var relativeName: String? {
            switch self {
            case .materialsJSON: return "materials.json"
            case .reviewPlansJSON: return "reviewPlans.json"
            case .settingsJSON: return "settings.json"
            case .examCountdownsJSON: return "examCountdowns.json"
            case .historyProgressJSON: return "historyProgress.json"
            case .learningProfileJSON: return "learningProfile.json"
            case .pdfAnnotationsJSON: return "pdfAnnotations.json"
            case .studySessionsJSON: return "studySessions.json"
            case .wrongQuestionsJSON: return "wrongQuestions.json"
            case .flashCardsJSON: return "flashCards.json"
            case .diaryEntriesJSON: return "diaryEntries.json"
            case .diaryCategoriesJSON: return "diaryCategories.json"
            case .p2pIdentityJSON: return "p2pIdentity.json"
            case .p2pFriendsJSON: return "p2pFriends.json"
            case .p2pBlackListJSON: return "p2pBlackList.json"
            case .p2pGroupsJSON: return "p2pGroups.json"
            case .p2pGroupMessages: return "p2pGroupMessages.enc"
            case .p2pMessages: return "p2pMessages.enc"
            case .todoItemsJSON: return "todoItems.json"
            case .habitsJSON: return "habits.json"
            case .todoCategoriesJSON: return "todoCategories.json"
            case .whiteboardsJSON: return "whiteboards.json"
            case .wishesJSON: return "wishes.json"
            case .anniversariesJSON: return "anniversaries.json"
            case .materialsDirectory: return "Materials"
            case .diaryImagesDirectory: return "DiaryImages"
            case .quickNotesDirectory: return "QuickNotes"
            case .backgroundImagesDirectory: return "BackgroundImages"
            case .ambientSoundsDirectory: return "AmbientSounds"
            case .pdfExportsDirectory: return "PDFExports"
            case .backupDirectory, .legacyBackupDirectory: return nil
            }
        }

        var isDirectory: Bool {
            switch self {
            case .materialsDirectory, .diaryImagesDirectory, .quickNotesDirectory,
                 .backgroundImagesDirectory, .ambientSoundsDirectory,
                 .pdfExportsDirectory, .backupDirectory, .legacyBackupDirectory:
                return true
            default:
                return false
            }
        }
    }

    private lazy var backupService = BackupService(sourceRoot: appSupportDirectory)
    private var backupDirectoryURL: URL { backupService.backupsDirectoryURL }
    private var legacyBackupDirectoryURL: URL { backupService.legacyBackupsDirectoryURL }

    private func managedURL(for path: ManagedDataPath) -> URL {
        switch path {
        case .backupDirectory:
            return backupDirectoryURL
        case .legacyBackupDirectory:
            return legacyBackupDirectoryURL
        default:
            guard let relativeName = path.relativeName else { return appSupportDirectory }
            return appSupportDirectory.appendingPathComponent(relativeName, isDirectory: path.isDirectory)
        }
    }

    /// 受管文件、目录以及运行时发现的 .corrupted-* 隔离副本。
    var managedDataURLs: [URL] {
        var urls = ManagedDataPath.allCases.map { managedURL(for: $0) }
        urls.append(contentsOf: corruptedCopyURLs())

        var seenPaths = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            return seenPaths.insert(path).inserted
        }
    }

    private var materialsFileURL: URL { managedURL(for: .materialsJSON) }

    private var reviewPlansFileURL: URL { managedURL(for: .reviewPlansJSON) }

    private var settingsFileURL: URL { managedURL(for: .settingsJSON) }

    private var examCountdownsFileURL: URL { managedURL(for: .examCountdownsJSON) }

    private var historyProgressFileURL: URL { managedURL(for: .historyProgressJSON) }

    private var learningProfileFileURL: URL { managedURL(for: .learningProfileJSON) }

    private var pdfAnnotationsFileURL: URL { managedURL(for: .pdfAnnotationsJSON) }

    private var studySessionsFileURL: URL { managedURL(for: .studySessionsJSON) }

    private var wrongQuestionsFileURL: URL { managedURL(for: .wrongQuestionsJSON) }

    private var flashCardsFileURL: URL { managedURL(for: .flashCardsJSON) }

    private var backgroundImagesDirectory: URL {
        let dir = managedURL(for: .backgroundImagesDirectory)
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                print("警告：无法创建背景图片目录 \(dir.path)：\(error.localizedDescription)")
            }
        }
        setDirectoryPermissions(dir)
        return dir
    }

    /// - Parameter appSupportDirectory: 仅供测试/隔离运行显式指定数据根目录；生产环境
    ///   使用 macOS Application Support 下的 SmartNote 目录。默认参数保持现有调用兼容。
    init(
        keychainService: KeychainService = KeychainService(),
        appSupportDirectory: URL? = nil
    ) {
        self.keychainService = keychainService
        if let appSupportDirectory {
            self.appSupportDirectory = appSupportDirectory.standardizedFileURL
        } else {
            let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            self.appSupportDirectory = paths.first!.appendingPathComponent("SmartNote")
        }

        do {
            try fileManager.createDirectory(at: self.appSupportDirectory, withIntermediateDirectories: true)
        } catch {
            // 保持原有容错行为：目录准备失败不阻止其它功能启动。
            print("警告：无法创建应用数据目录 \(self.appSupportDirectory.path)：\(error.localizedDescription)")
        }
        setDirectoryPermissions(self.appSupportDirectory)
    }
    
    func saveMaterials(_ materials: [StudyMaterial]) {
        save(materials, to: materialsFileURL)
    }

    func loadMaterials() -> [StudyMaterial] {
        load(from: materialsFileURL) ?? []
    }

    // MARK: - 考试倒计时（AppState 为唯一真相源，独立文件持久化）

    func saveExamCountdowns(_ exams: [ExamCountdown]) {
        save(exams, to: examCountdownsFileURL)
    }

    func loadExamCountdowns() -> [ExamCountdown] {
        load(from: examCountdownsFileURL) ?? []
    }

    // MARK: - 中国近代史学习进度

    @discardableResult
    func saveHistoryProgress(_ progress: HistoryLearningState) -> Bool {
        save(progress, to: historyProgressFileURL)
    }

    func loadHistoryProgressResult() -> HistoryProgressLoadResult {
        let fileExists = fileManager.fileExists(atPath: historyProgressFileURL.path)
        guard fileExists else {
            return HistoryProgressLoadResult(state: HistoryLearningState(), fileExists: false, didFailToDecode: false)
        }
        guard let state: HistoryLearningState = load(from: historyProgressFileURL) else {
            return HistoryProgressLoadResult(state: HistoryLearningState(), fileExists: true, didFailToDecode: true)
        }
        return HistoryProgressLoadResult(state: state, fileExists: true, didFailToDecode: false)
    }

    func loadHistoryProgress() -> HistoryLearningState {
        loadHistoryProgressResult().state
    }

    func deleteHistoryProgress() {
        try? fileManager.removeItem(at: historyProgressFileURL)
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

        // 1. 仅当检测到"低于当前 schema"才备份一次。若 API key 迁移尚未完成，
        //    不能再把含明文凭据的 settings.json 复制到新的未加密备份。
        if working.schemaVersion < Self.currentSchemaVersion {
            if legacyAPIKeyMigrationPending {
                backupError = NSError(
                    domain: "StorageService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "settings.json 仍有待迁移的 API key，已跳过备份以避免复制明文凭据。"]
                )
            } else {
                do {
                    createdBackupURL = try backupService.makeBackup(
                        label: "pre-migration-v\(working.schemaVersion)-to-v\(Self.currentSchemaVersion)"
                    )
                } catch {
                    backupError = error
                }
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
    
    /// 保存设置。API key 先写入 Keychain，成功后才允许把不含 key 的 JSON 写盘。
    /// 保留 Bool 返回值而不是 throws，以兼容现有大量忽略返回值的调用方；失败会通过
    /// `storageSettingsPersistenceIssue` 通知和 `settingsPersistenceError` 供 UI 感知。
    @discardableResult
    func saveSettings(_ settings: AppSettings) -> Bool {
        let configuration = settings.llmConfiguration
        let account = configuration.keychainAccount

        do {
            if configuration.apiKey.isEmpty {
                guard keychainService.deleteString(for: account) else {
                    Self.reportSettingsPersistenceIssue("无法清除 API key：Keychain 删除失败。")
                    return false
                }
            } else {
                try keychainService.setString(configuration.apiKey, for: account)
            }
        } catch {
            // 绝不能把 apiKey 作为 JSON fallback 写盘。
            Self.reportSettingsPersistenceIssue("API key 保存到 Keychain 失败：\(error.localizedDescription)")
            return false
        }

        guard save(settings, to: settingsFileURL) else {
            Self.reportSettingsPersistenceIssue("settings.json 写入失败，API key 未写入磁盘。")
            return false
        }
        Self.clearSettingsPersistenceIssue()
        return true
    }

    /// 读取设置并从 Keychain 注入 API key。
    /// 旧版本 JSON 中仍有明文 key 时，先成功存入 Keychain，再重写文件剥离凭据；
    /// 任一步失败都保留原文件，等待下一次 load 重试。
    func loadSettings() -> AppSettings {
        legacyAPIKeyMigrationPending = false
        guard let settings: AppSettings = load(from: settingsFileURL) else {
            return AppSettings()
        }

        let account = settings.llmConfiguration.keychainAccount
        if let legacyKey = legacyAPIKeyInSettingsFile(), !legacyKey.isEmpty {
            do {
                // 若前一次保存已经把更新的 key 放进 Keychain，以 Keychain 为准，
                // 避免用可能过时的磁盘明文覆盖它。
                let existingKey = try keychainService.readString(for: account)
                let securedKey: String
                if let existingKey, !existingKey.isEmpty {
                    securedKey = existingKey
                } else {
                    try keychainService.setString(legacyKey, for: account)
                    securedKey = legacyKey
                }
                var migratedConfiguration = settings.llmConfiguration
                migratedConfiguration.apiKey = securedKey
                settings.llmConfiguration = migratedConfiguration

                if save(settings, to: settingsFileURL) {
                    legacyAPIKeyMigrationPending = false
                    Self.clearSettingsPersistenceIssue()
                } else {
                    legacyAPIKeyMigrationPending = true
                    Self.reportSettingsPersistenceIssue("旧 API key 已安全保存，但暂时无法从 settings.json 剥离；下次加载会重试。")
                }
            } catch {
                // 不删除、不覆盖旧文件，避免迁移失败导致 key 丢失。
                var unmigratedConfiguration = settings.llmConfiguration
                unmigratedConfiguration.apiKey = legacyKey
                settings.llmConfiguration = unmigratedConfiguration
                legacyAPIKeyMigrationPending = true
                Self.reportSettingsPersistenceIssue("旧 API key 迁移失败，原文保留并将在下次加载重试：\(error.localizedDescription)")
            }
        } else {
            do {
                if let key = try keychainService.readString(for: account) {
                    settings.llmConfiguration.apiKey = key
                }
            } catch {
                // 没有 key 时仍返回其它设置；错误会留在 UI，避免误以为凭据已保存。
                Self.reportSettingsPersistenceIssue("读取 Keychain 中的 API key 失败：\(error.localizedDescription)")
            }
        }
        return settings
    }

    /// 直接检查原始 JSON，避免把已经从 Keychain 注入的内存 key 误判成待迁移明文。
    private func legacyAPIKeyInSettingsFile() -> String? {
        guard let data = try? Data(contentsOf: settingsFileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let llm = root["llmConfiguration"] as? [String: Any],
              let key = llm["apiKey"] as? String,
              !key.isEmpty else {
            return nil
        }
        return key
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
    
    private var diaryEntriesFileURL: URL { managedURL(for: .diaryEntriesJSON) }

    private var diaryCategoriesFileURL: URL { managedURL(for: .diaryCategoriesJSON) }
    
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
    
    private var p2pIdentityFileURL: URL { managedURL(for: .p2pIdentityJSON) }

    private var p2pFriendsFileURL: URL { managedURL(for: .p2pFriendsJSON) }

    private var p2pBlackListFileURL: URL { managedURL(for: .p2pBlackListJSON) }
    
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
    
    private var p2pGroupsFileURL: URL { managedURL(for: .p2pGroupsJSON) }

    var p2pGroupMessagesFileURL: URL { managedURL(for: .p2pGroupMessages) }

    var p2pMessagesFileURL: URL { managedURL(for: .p2pMessages) }
    
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
    
    private var todoItemsFileURL: URL { managedURL(for: .todoItemsJSON) }

    private var habitsFileURL: URL { managedURL(for: .habitsJSON) }

    private var todoCategoriesFileURL: URL { managedURL(for: .todoCategoriesJSON) }
    
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
            setDirectoryPermissions(backgroundImagesDirectory)
            setFilePermissions(destinationURL)
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
    
    @discardableResult
    private func save<T: Encodable>(_ object: T, to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(object)
            try data.write(to: url, options: .atomic)
            // 写入（包括原子替换）完成后再收紧权限；失败只记录日志，不影响数据可用性。
            setDirectoryPermissions(url.deletingLastPathComponent())
            setFilePermissions(url)
            return true
        } catch {
            print("Error saving to \(url): \(error)")
            return false
        }
    }

    private func setDirectoryPermissions(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path
            )
        } catch {
            print("警告：无法收紧目录权限 \(url.path)：\(error.localizedDescription)")
        }
    }

    private func setFilePermissions(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        } catch {
            print("警告：无法收紧文件权限 \(url.path)：\(error.localizedDescription)")
        }
    }

    private func load<T: Decodable>(from url: URL) -> T? {
        // 文件不存在是首次使用的正常路径，不应产生损坏警告或隔离副本。
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            reportStorageIntegrityIssue(for: url, reason: "读取失败：\(error.localizedDescription)")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            reportStorageIntegrityIssue(for: url, reason: "JSON 解码失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 处理 P2P 等无法直接复用 JSON load(from:) 的加密文件读取失败。
    /// 原文件保留；调用方仍可继续使用空集合，但必须自行决定是否允许写回。
    func reportStorageIntegrityIssue(for url: URL, reason: String) {
        let copyURL = makeCorruptedCopy(of: url)
        let copyDescription: String
        if let copyURL = copyURL {
            copyDescription = "已隔离为 \(copyURL.lastPathComponent)"
        } else {
            copyDescription = "隔离副本创建失败，原文件仍保留"
        }

        let message = "文件 \(url.path) \(reason)；\(copyDescription)"
        let issue = StorageIntegrityIssue(fileURL: url, message: message)
        Self.integrityIssuesLock.lock()
        Self.recordedIntegrityIssues.append(issue)
        Self.integrityIssuesLock.unlock()

        print("[StorageIntegrity] \(message)")
        NotificationCenter.default.post(
            name: .storageIntegrityIssue,
            object: self,
            userInfo: [
                "fileURL": url,
                "message": message
            ]
        )
    }

    private func makeCorruptedCopy(of url: URL) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let baseName = url.deletingPathExtension().lastPathComponent
        let extensionName = url.pathExtension
        let copiedName: String
        if extensionName.isEmpty {
            copiedName = "\(baseName).corrupted-\(stamp)"
        } else {
            copiedName = "\(baseName).corrupted-\(stamp).\(extensionName)"
        }

        var destination = url.deletingLastPathComponent().appendingPathComponent(copiedName)
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            let suffixName: String
            if extensionName.isEmpty {
                suffixName = "\(baseName).corrupted-\(stamp)-\(counter)"
            } else {
                suffixName = "\(baseName).corrupted-\(stamp)-\(counter).\(extensionName)"
            }
            destination = url.deletingLastPathComponent().appendingPathComponent(suffixName)
            counter += 1
        }

        do {
            try fileManager.copyItem(at: url, to: destination)
            setFilePermissions(destination)
            return destination
        } catch {
            print("警告：无法为损坏文件创建隔离副本 \(url.path)：\(error.localizedDescription)")
            return nil
        }
    }

    private func corruptedCopyURLs() -> [URL] {
        var roots = [appSupportDirectory, backupDirectoryURL, legacyBackupDirectoryURL]
        var seenRootPaths = Set<String>()
        roots = roots.filter { seenRootPaths.insert($0.standardizedFileURL.path).inserted }

        var urlsByPath: [String: URL] = [:]
        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.lastPathComponent.contains(".corrupted-") else { continue }
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                urlsByPath[fileURL.standardizedFileURL.path] = fileURL
            }
        }
        return Array(urlsByPath.values)
    }

    private func removeManagedItem(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            print("警告：清除受管数据失败 \(url.path)：\(error.localizedDescription)")
        }
    }

    func clearAllData() {
        // 先删隔离副本和子目录，再删清单中的文件；每一项独立处理，单项失败不阻断其余清理。
        let urls = managedDataURLs.sorted {
            $0.pathComponents.count > $1.pathComponents.count
        }
        for url in urls {
            removeManagedItem(at: url)
        }

        let accountsBeforeDelete = keychainService.listAccounts()
        keychainService.deleteAll()
        let remainingAccounts = keychainService.listAccounts()
        if !accountsBeforeDelete.isEmpty && !remainingAccounts.isEmpty {
            print("警告：仍有 \(remainingAccounts.count) 个受管钥匙串条目未能清除")
        } else {
            Self.clearSettingsPersistenceIssue()
        }

        Self.dismissIntegrityIssues()
        NotificationCenter.default.post(name: .storageDidClearAllData, object: self)
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
        var countedDirectories = Set<String>()

        // 清单同时包含目录和目录内的 .corrupted-* 文件，按父目录优先避免重复统计。
        for url in managedDataURLs.sorted(by: { $0.pathComponents.count < $1.pathComponents.count }) {
            let path = url.standardizedFileURL.path
            if countedDirectories.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                continue
            }

            if isDirectory(url) {
                countedDirectories.insert(path)
            }
            totalSize += size(of: url)
        }
        return totalSize
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &directory) else { return false }
        return directory.boolValue
    }

    private func size(of url: URL) -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else { return 0 }

        if isDirectory(url) {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
            ) else { return 0 }

            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
            return total
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

struct HistoryProgressLoadResult {
    let state: HistoryLearningState
    let fileExists: Bool
    let didFailToDecode: Bool
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
    /// 主题只负责视觉层；经典主题继续遵循“外观”中的明暗模式设置。
    @Published var themeID: ThemeID = .classic
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
        lhs.themeID == rhs.themeID &&
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

    enum ThemeID: String, Codable, CaseIterable, Identifiable {
        case classic
        case nationalDay
        case auspicious

        var id: String { rawValue }

        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            // 未来版本新增或误写的值不能让整个 settings.json 解码失败。
            self = Self(rawValue: rawValue) ?? .classic
        }
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
        case themeID
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
        case p2pBackgroundEnabled
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
        themeID = .classic
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
        p2pBackgroundEnabled = false
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
        themeID = try container.decodeIfPresent(ThemeID.self, forKey: .themeID) ?? .classic
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
        p2pBackgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .p2pBackgroundEnabled) ?? false
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
        try container.encode(themeID, forKey: .themeID)
        try container.encode(calendarIntegrationEnabled, forKey: .calendarIntegrationEnabled)
        try container.encode(reminderEnabled, forKey: .reminderEnabled)
        try container.encode(defaultStudyMinutes, forKey: .defaultStudyMinutes)
        try container.encode(showFileExtensions, forKey: .showFileExtensions)
        try container.encode(llmConfiguration, forKey: .llmConfiguration)
        try container.encode(pomodoroWorkDuration, forKey: .pomodoroWorkDuration)
        try container.encode(pomodoroBreakDuration, forKey: .pomodoroBreakDuration)
        // examCountdowns 故意不再写入 settings.json：唯一真相源是 AppState.examCountdowns，
        // 它持久化在 examCountdowns.json，避免"设置旧快照覆盖新列表"导致考试消失/复活。
        // 旧 settings.json 里的该键仍可解码，仅用于一次性迁移。
        try container.encode(autoUpdateEnabled, forKey: .autoUpdateEnabled)
        try container.encode(updateChannel, forKey: .updateChannel)
        try container.encode(updateRepoOwner, forKey: .updateRepoOwner)
        try container.encode(updateRepoName, forKey: .updateRepoName)
        try container.encode(updateCheckIntervalHours, forKey: .updateCheckIntervalHours)
        try container.encodeIfPresent(lastUpdateCheckDate, forKey: .lastUpdateCheckDate)
        try container.encodeIfPresent(lastFoundReleaseName, forKey: .lastFoundReleaseName)
        try container.encode(p2pBackgroundEnabled, forKey: .p2pBackgroundEnabled)
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
