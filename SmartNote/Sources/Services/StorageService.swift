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
    
    enum DarkModePreference: String, Codable, Equatable {
        case system
        case light
        case dark
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
    }
}

struct ExportData: Codable {
    let materials: [StudyMaterial]
    let reviewPlans: [ReviewPlan]
    let exportedAt: Date
}
