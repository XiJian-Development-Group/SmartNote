import Foundation

final class DiaryService: ObservableObject {
    static let shared = DiaryService()

    @Published var entries: [DiaryEntry] = []
    @Published var categories: [DiaryCategory] = []

    private let storageService = StorageService()
    private let encryptionService = DiaryEncryptionService.shared

    private init() {
        loadData()
    }

    private func loadData() {
        // 启动时完成旧版 UserDefaults -> Keychain 迁移；失败由加密服务保留旧数据并记录日志。
        do {
            try encryptionService.migrateLegacySettingsIfNeeded()
        } catch {
            print("[DiaryService] 日记加密设置迁移失败，保留旧数据：\(error.localizedDescription)")
        }
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

    /// 保存新日记。加密开启时，正文加密失败会返回 failure，既不会把明文当成功
    /// 结果写入内存，也不会写入日记库。调用方必须展示错误并保持编辑器打开。
    @discardableResult
    func addEntry(_ entry: DiaryEntry) -> Result<Void, DiaryEncryptionError> {
        do {
            let preparedEntry = try prepareEntryForSave(entry)
            entries.append(preparedEntry)
            saveEntries()
            return .success(())
        } catch let error as DiaryEncryptionError {
            return .failure(error)
        } catch {
            return .failure(.encryptionFailed(error.localizedDescription))
        }
    }

    /// 更新日记。失败时不替换 entries 中的旧值，避免失败后误以为新内容已保存。
    @discardableResult
    func updateEntry(_ entry: DiaryEntry) -> Result<Void, DiaryEncryptionError> {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return .success(())
        }

        do {
            var entryToSave = entry
            entryToSave.updatedAt = Date()
            let preparedEntry = try prepareEntryForSave(entryToSave)
            entries[index] = preparedEntry
            saveEntries()
            return .success(())
        } catch let error as DiaryEncryptionError {
            return .failure(error)
        } catch {
            return .failure(.encryptionFailed(error.localizedDescription))
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

    /// 读取加密日记。失败时返回明确的 Result.failure；不会用空字符串或原始密文
    /// 冒充“解密成功”。旧 CBC 读取后，编辑器下次保存会由 prepareEntryForSave
    /// 自动重写为当前 AES-GCM 格式。
    func decryptEntry(_ entry: DiaryEntry) -> Result<DiaryEntry, DiaryEncryptionError> {
        guard entry.isEncrypted else { return .success(entry) }

        do {
            let password: String
            do {
                password = try encryptionService.passwordForEncryption()
            } catch {
                // 读取加密日记时没有可用密码，对用户而言是认证失败，不应显示
                // “未配置密码”或返回空内容。
                return .failure(.wrongPassword)
            }
            return .success(try encryptionService.decryptDiary(entry, password: password))
        } catch let error as DiaryEncryptionError {
            return .failure(error)
        } catch {
            return .failure(.corruptedData)
        }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "zh_CN")

        var result: [(month: String, count: Int)] = []
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

        var result: [(date: Date, count: Int)] = []
        for i in (0..<days).reversed() {
            guard let dayStart = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            let dayLabel = calendar.startOfDay(for: dayStart)
            let count = entries.filter { entry in
                calendar.isDate(entry.createdAt, inSameDayAs: dayLabel)
            }.reduce(0) { $0 + $1.chineseWordCount }
            result.append((dayLabel, count))
        }

        return result
    }

    private func prepareEntryForSave(_ entry: DiaryEntry) throws -> DiaryEntry {
        let settings = encryptionService.loadEncryptionSettings()

        if settings.isEnabled {
            // 没有 Keychain 密码时失败关闭；绝不能跳过加密后把明文写入日记库。
            let password = try encryptionService.passwordForEncryption()
            let plaintextEntry: DiaryEntry
            if entry.isEncrypted {
                // 允许旧的 CBC/GCM entry 被直接更新：先读出明文，再写成新 GCM。
                plaintextEntry = try encryptionService.decryptDiary(entry, password: password)
            } else {
                plaintextEntry = entry
            }
            return try encryptionService.encryptDiary(plaintextEntry, password: password)
        }

        if entry.isEncrypted {
            // 用户明确关闭加密后，仍必须先成功解密，才能安全地写成明文；不能把
            // 密文字符串当作正文直接落盘。
            let password = try encryptionService.passwordForEncryption()
            return try encryptionService.decryptDiary(entry, password: password)
        }

        var plaintextEntry = entry
        plaintextEntry.isEncrypted = false
        return plaintextEntry
    }

    private func saveEntries() {
        storageService.saveDiaryEntries(entries)
    }

    private func saveCategories() {
        storageService.saveDiaryCategories(categories)
    }
}
