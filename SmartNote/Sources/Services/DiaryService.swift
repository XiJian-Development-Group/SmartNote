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
    
    // MARK: - 统计
    
    /// 连续写日记的天数（以今天为终点，向前推算）
    var continuousWritingDays: Int {
        let calendar = Calendar.current
        // 获取所有有日记的日期（去重）
        let writingDays = Set(entries.map { calendar.startOfDay(for: $0.createdAt) })
        
        guard !writingDays.isEmpty else { return 0 }
        
        let today = calendar.startOfDay(for: Date())
        var current = today
        var count = 0
        
        // 如果今天没写，从昨天开始算
        if !writingDays.contains(current) {
            current = calendar.date(byAdding: .day, value: -1, to: current) ?? current
        }
        
        while writingDays.contains(current) {
            count += 1
            current = calendar.date(byAdding: .day, value: -1, to: current) ?? current
        }
        
        return count
    }
    
    /// 日记总数
    var totalEntries: Int {
        entries.count
    }
    
    /// 日记总字数（中英文混合统计）
    var totalWordCount: Int {
        entries.reduce(0) { $0 + $1.chineseWordCount }
    }
    
    /// 按分类统计
    func countByCategory() -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in entries {
            result[entry.category, default: 0] += 1
        }
        return result
    }
    
    /// 按月份统计（最近12个月）
    func countByMonth(months: Int = 12) -> [(month: String, count: Int)] {
        let calendar = Calendar.current
        let now = Date()
        var result: [(String, Int)] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "zh_CN")
        
        for i in (0..<months).reversed() {
            guard let monthStart = calendar.date(byAdding: .month, value: -i, to: now) else { continue }
            let monthLabel = formatter.string(from: monthStart)
            let count = entries.filter { entry in
                calendar.isDate(entry.createdAt, equalTo: monthStart, toGranularity: .month)
            }.count
            result.append((monthLabel, count))
        }
        return result
    }
    
    /// 每日字数统计（最近 30 天）
    func wordCountByDay(days: Int = 30) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let now = Date()
        var result: [(Date, Int)] = []
        
        for i in (0..<days).reversed() {
            guard let dayStart = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            let day = calendar.startOfDay(for: dayStart)
            let count = entries.filter { entry in
                calendar.isDate(entry.createdAt, inSameDayAs: day)
            }.reduce(0) { $0 + $1.chineseWordCount }
            result.append((day, count))
        }
        return result
    }
    
    private func saveEntries() {
        storageService.saveDiaryEntries(entries)
    }
    
    private func saveCategories() {
        storageService.saveDiaryCategories(categories)
    }
}
