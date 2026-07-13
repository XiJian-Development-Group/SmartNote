import Foundation

class StorageService {
    private let fileManager = FileManager.default
    private let appSupportDirectory: URL
    
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

struct AppSettings: Codable, Equatable {
    var autoScanDirectories: Bool = true
    var scanPaths: [String] = []
    var darkModePreference: DarkModePreference = .system
    var calendarIntegrationEnabled: Bool = true
    var reminderEnabled: Bool = true
    var defaultStudyMinutes: Int = 30
    var showFileExtensions: Bool = true
    var llmConfiguration: LLMConfiguration = LLMConfiguration()
    var pomodoroWorkDuration: Int = 25
    var pomodoroBreakDuration: Int = 5
    var examCountdowns: [ExamCountdown] = []
    var autoUpdateEnabled: Bool = false
    var updateChannel: UpdateChannel = .latest
    var updateRepoOwner: String = "XiJian-Development-Group"
    var updateRepoName: String = "SmartNote"
    var updateCheckIntervalHours: Int = 24
    var lastUpdateCheckDate: Date? = nil
    var lastFoundReleaseName: String? = nil
    var p2pBackgroundEnabled: Bool = false
    
    // Background image settings
    var backgroundImageEnabled: Bool = false
    var backgroundImageName: String? = nil
    var backgroundBlurEnabled: Bool = true
    var backgroundBlurRadius: Double = 20.0
    var backgroundOpacity: Double = 0.3
    
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
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
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
