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
    
    enum DarkModePreference: String, Codable, Equatable {
        case system
        case light
        case dark
    }
}

struct ExportData: Codable {
    let materials: [StudyMaterial]
    let reviewPlans: [ReviewPlan]
    let exportedAt: Date
}
