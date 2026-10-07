import Foundation
import Combine

/// 答案之书。
///
/// 目录来自应用包内的 `answer_book.json`（与 `history_catalog.json` 同一套做法）：
/// 加载失败时置 `loadError`，界面显示橙色横幅与「重试」按钮，修好文件后不必重启。
///
/// 历史记录走 `StorageService`，因此天然具备原子写、权限 600、损坏文件隔离为
/// `.corrupted-*`、进备份以及被「清除所有数据」清理这几项保障。
@MainActor
final class AnswerBookService: ObservableObject {
    /// 历史保留上限。超出后丢弃最早的一条。
    static let historyLimit = 100
    /// 问题长度上限。界面的输入限制只是提示，这里是真正的拦截。
    static let questionLimit = 100
    /// 稀有条目的命中概率。命中后从稀有池里再随机取一条。
    static let specialDrawRate: Double = 0.04

    @Published private(set) var entries: [AnswerBookEntry] = []
    @Published private(set) var catalogVersion: String = ""
    @Published private(set) var catalogNote: String = ""
    @Published private(set) var history = AnswerBookHistoryState()
    /// 目录读取失败原因。
    @Published private(set) var loadError: String?
    /// 历史写盘失败原因。成功写盘后清空。
    @Published private(set) var saveError: String?

    private let storage: StorageService
    private var didLoadCatalog = false
    private var canPersistHistory = true

    init(storage: StorageService = StorageService()) {
        self.storage = storage
        loadCatalogIfNeeded()
        reloadHistory()
    }

    // MARK: - 库信息

    var normalEntries: [AnswerBookEntry] { entries.filter { $0.kind == .normal } }

    var specialEntries: [AnswerBookEntry] { entries.filter(\.isSpecial) }

    var isCatalogReady: Bool { !entries.isEmpty }

    func entry(id: Int) -> AnswerBookEntry? {
        entries.first { $0.id == id }
    }

    // MARK: - 历史

    var records: [AnswerBookRecord] { history.records }

    var favoriteRecords: [AnswerBookRecord] { history.favoriteRecords }

    var lastRecord: AnswerBookRecord? { history.records.first }

    /// 抽一条答案。
    ///
    /// - Parameter excluding: 需要排除的答案 id，「换一个」时传当前这条，
    ///   避免连续两次给出同一个答案。为空时自动排除上一次的结果。
    /// - Returns: 命中的答案；库为空时返回 `nil`。
    func drawAnswer(excluding excludedID: Int? = nil) -> AnswerBookEntry? {
        guard !entries.isEmpty else { return nil }

        let excluded = excludedID ?? history.lastEntryID
        // 只对实际存在的条目做随机，不按「编号上界」抽：
        // 搬迁前的实现用 randint(0, MaxId) 取编号，编号一旦有缺口就会抽空，
        // 直接对数组 randomElement() 从根上不会有这个缺口。
        let normal = normalEntries.filter { $0.id != excluded }
        let special = specialEntries.filter { $0.id != excluded }

        let pool: [AnswerBookEntry]
        if !special.isEmpty, Double.random(in: 0..<1) < Self.specialDrawRate {
            pool = special
        } else if !normal.isEmpty {
            pool = normal
        } else if !special.isEmpty {
            pool = special
        } else {
            // 库只剩一条时（被排除的那条）允许重复，也好过不给答案。
            pool = entries
        }

        return pool.randomElement()
    }

    /// 校验问题文本。返回 `nil` 表示可以继续。
    func validate(question: String) -> String? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "请先写下你的问题。"
        }
        if trimmed.count > Self.questionLimit {
            return "问题太长了，最多 \\(Self.questionLimit) 个字。"
        }
        if !isCatalogReady {
            return loadError ?? "答案库未加载，无法测定。"
        }
        return nil
    }

    /// 记录一次测定。返回写入的这条记录；写盘结果由 `saveError` 反映。
    @discardableResult
    func record(question: String, entry: AnswerBookEntry) -> AnswerBookRecord {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = AnswerBookRecord(
            question: trimmed,
            answer: entry.content,
            entryID: entry.id,
            kind: entry.kind
        )
        history.records.insert(record, at: 0)
        history.lastEntryID = entry.id
        if history.records.count > Self.historyLimit {
            history.records = Array(history.records.prefix(Self.historyLimit))
        }
        persistHistory()
        return record
    }

    /// 「换一个」：把已有的某次测定改成新的答案，不新增历史条目。
    /// 同一次测定反复翻页只应留下一条记录，否则历史会被同一个问题刷屏。
    @discardableResult
    func update(recordID: UUID, entry: AnswerBookEntry) -> Bool {
        guard let index = history.records.firstIndex(where: { $0.id == recordID }) else { return false }
        history.records[index].answer = entry.content
        history.records[index].entryID = entry.id
        history.records[index].kind = entry.kind
        history.lastEntryID = entry.id
        persistHistory()
        return true
    }

    func record(id: UUID) -> AnswerBookRecord? {
        history.records.first { $0.id == id }
    }

    @discardableResult
    func toggleFavorite(recordID: UUID) -> Bool? {
        guard let index = history.records.firstIndex(where: { $0.id == recordID }) else { return nil }
        history.records[index].isFavorite.toggle()
        persistHistory()
        return history.records[index].isFavorite
    }

    func remove(recordID: UUID) {
        history.records.removeAll { $0.id == recordID }
        persistHistory()
    }

    /// 从磁盘重读历史。「清除所有数据」之后由 `AppState` 调用。
    func reloadHistory() {
        let result = storage.loadAnswerBookHistoryResult()
        history = result.state
        canPersistHistory = !result.didFailToDecode
        if result.didFailToDecode {
            saveError = Self.corruptedHistoryMessage
        } else if saveError == Self.corruptedHistoryMessage {
            saveError = nil
        }
    }

    /// 历史文件读不出来时的提示。
    ///
    /// 注意措辞必须与真实行为一致：解码失败后 `canPersistHistory` 为 false，
    /// 新的测定只留在内存里、**不会**写盘（写回会把用户还能手工抢救的内容覆盖掉）。
    private static let corruptedHistoryMessage =
        "答案之书历史文件无法读取，已把原文件隔离备份在同一目录；新的测定不会写盘，以免覆盖它。删除该文件并重启应用即可重新开始记录。"

    func clearSaveError() { saveError = nil }

    // MARK: - 目录加载

    /// 重新加载目录。失败时 `didLoadCatalog` 会被复位，用户修好文件后可直接重试。
    /// - Returns: 是否加载成功。
    @discardableResult
    func retryLoadCatalog() -> Bool {
        didLoadCatalog = false
        loadCatalogIfNeeded()
        return loadError == nil
    }

    private func loadCatalogIfNeeded() {
        guard !didLoadCatalog else { return }
        didLoadCatalog = true
        loadCatalog()
    }

    private func loadCatalog() {
        guard let url = Bundle.main.url(forResource: "answer_book", withExtension: "json") else {
            didLoadCatalog = false
            loadError = "未找到答案库资源 answer_book.json。"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(AnswerBookCatalog.self, from: data)
            let ids = catalog.answers.map(\.id)
            guard Set(ids).count == ids.count else {
                didLoadCatalog = false
                loadError = "答案库存在重复的条目编号，未加载该文件。"
                return
            }
            guard !catalog.answers.isEmpty else {
                didLoadCatalog = false
                loadError = "答案库为空，未加载该文件。"
                return
            }
            entries = catalog.answers
            catalogVersion = catalog.version
            catalogNote = catalog.note
            loadError = nil
        } catch {
            didLoadCatalog = false
            loadError = "答案库加载失败：\\(error.localizedDescription)"
        }
    }

    // MARK: - 写盘

    private func persistHistory() {
        let persistenceMessage = "答案之书历史保存失败，请检查本机数据目录权限。"
        guard canPersistHistory else { return }
        guard storage.saveAnswerBookHistory(history) else {
            saveError = persistenceMessage
            return
        }
        if saveError == persistenceMessage {
            saveError = nil
        }
    }

    /// 退出前把内存态写盘。历史本来就每次操作后落盘，
    /// 这里用于恢复备份等需要确保「内存态已同步」的场景。
    func flushHistory() {
        persistHistory()
    }
}
