import Foundation

class DiaryService: ObservableObject {
    static let shared = DiaryService()
    
    @Published var entries: [DiaryEntry] = []
    @Published var categories: [DiaryCategory] = []
    
    private let storageService = StorageService()
    private let encryptionService = DiaryEncryptionService.shared
    
    private init() {
        loadData()
    }
    
    private func loadData() {
        entries = storageService.loadDiaryEntries()
        categories = storageService.loadDiaryCategories()
        
        if categories.isEmpty {
            categories = [
                DiaryCategory(name: "默认", color: "#007AFF"),
                DiaryCategory(name: "学习", color: "#34C759"),
                DiaryCategory(name: "生活", color: "#FF9500"),
                DiaryCategory(name: "工作", color: "#AF52DE")
            ]
            saveCategories()
        }
    }
    
    func addEntry(_ entry: DiaryEntry) {
        var newEntry = entry
        
        if encryptionService.isEncryptionEnabled() && encryptionService.loadEncryptionSettings().password.isEmpty == false {
            newEntry = encryptionService.encryptDiary(entry, password: encryptionService.loadEncryptionSettings().password)
        }
        
        entries.append(newEntry)
        saveEntries()
    }
    
    func updateEntry(_ entry: DiaryEntry) {
        var updatedEntry = entry
        updatedEntry.updatedAt = Date()
        
        if encryptionService.isEncryptionEnabled() && encryptionService.loadEncryptionSettings().password.isEmpty == false {
            updatedEntry = encryptionService.encryptDiary(updatedEntry, password: encryptionService.loadEncryptionSettings().password)
        }
        
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = updatedEntry
            saveEntries()
        }
    }
    
    func deleteEntries(_ ids: [UUID]) {
        entries.removeAll { ids.contains($0.id) }
        saveEntries()
    }
    
    func pinEntry(_ id: UUID) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index].isPinned.toggle()
            saveEntries()
        }
    }
    
    func searchEntries(query: String, date: Date? = nil) -> [DiaryEntry] {
        var results = entries
        
        if let date = date {
            let calendar = Calendar.current
            results = results.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
        }
        
        if !query.isEmpty {
            results = results.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        
        return results.sorted { entry1, entry2 in
            if entry1.isPinned != entry2.isPinned {
                return entry1.isPinned
            }
            return entry1.createdAt > entry2.createdAt
        }
    }
    
    func getEntriesForDate(_ date: Date) -> [DiaryEntry] {
        let calendar = Calendar.current
        return entries.filter { calendar.isDate($0.createdAt, inSameDayAs: date) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    
    func getEntriesForCategory(_ category: String) -> [DiaryEntry] {
        return entries.filter { $0.category == category }
    }
    
    func addCategory(_ category: DiaryCategory) {
        categories.append(category)
        saveCategories()
    }
    
    func deleteCategories(_ ids: [UUID]) {
        categories.removeAll { ids.contains($0.id) }
        saveCategories()
    }
    
    func decryptEntry(_ entry: DiaryEntry) -> DiaryEntry? {
        guard entry.isEncrypted else { return entry }
        
        let password = encryptionService.loadEncryptionSettings().password
        return encryptionService.decryptDiary(entry, password: password)
    }
    
    private func saveEntries() {
        storageService.saveDiaryEntries(entries)
    }
    
    private func saveCategories() {
        storageService.saveDiaryCategories(categories)
    }
}
