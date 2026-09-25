import Foundation
import SwiftUI

@MainActor
final class HistoryService: ObservableObject {
    @Published private(set) var articles: [HistoryArticle] = []
    @Published private(set) var learningState = HistoryLearningState()
    @Published private(set) var catalogNote = "本项目采用中国大陆常用的中国近代史分期（1840—1949）。"
    @Published private(set) var loadError: String?

    private let storageService: StorageService
    private var didLoadCatalog = false
    private var canPersistProgress = true

    init(storageService: StorageService) {
        self.storageService = storageService
        loadCatalogIfNeeded()
        reloadProgress()
    }

    var allTags: [String] {
        Array(Set(articles.flatMap(\.tags))).sorted()
    }

    var completedCount: Int {
        articles.filter { isCompleted($0.id) }.count
    }

    var favoriteCount: Int {
        articles.filter { isFavorite($0.id) }.count
    }

    var recentArticles: [HistoryArticle] {
        learningState.recentArticleIDs.compactMap { article(id: $0) }
    }

    var lastRandomArticle: HistoryArticle? {
        learningState.lastRandomArticleID.flatMap { article(id: $0) }
    }

    func article(id: String) -> HistoryArticle? {
        articles.first { $0.id == id }
    }

    func search(
        query: String,
        period: HistoryPeriod?,
        tag: String?,
        favoritesOnly: Bool
    ) -> [HistoryArticle] {
        let terms = Self.normalizedSearchTerms(query)
        return articles
            .filter { article in
                let matchesPeriod = period == nil || article.period == period
                let matchesTag = tag.map { article.tags.contains($0) } ?? true
                let matchesFavorite = !favoritesOnly || isFavorite(article.id)
                let haystack = Self.normalize(article.searchableText)
                let matchesQuery = terms.isEmpty || terms.allSatisfy { haystack.contains($0) }
                return matchesPeriod && matchesTag && matchesFavorite && matchesQuery
            }
            .sorted { lhs, rhs in
                if lhs.startYear != rhs.startYear { return lhs.startYear < rhs.startYear }
                return lhs.title < rhs.title
            }
    }

    func isFavorite(_ articleID: String) -> Bool {
        learningState.progressByArticleID[articleID]?.isFavorite == true
    }

    func isCompleted(_ articleID: String) -> Bool {
        learningState.progressByArticleID[articleID]?.isCompleted == true
    }

    func isSectionCompleted(articleID: String, sectionID: String) -> Bool {
        learningState.progressByArticleID[articleID]?.completedSectionIDs.contains(sectionID) == true
    }

    func toggleFavorite(_ articleID: String) {
        guard article(id: articleID) != nil else { return }
        var progress = learningState.progressByArticleID[articleID] ?? HistoryArticleProgress()
        progress.isFavorite.toggle()
        learningState.progressByArticleID[articleID] = progress
        persistProgress()
    }

    func markOpened(_ articleID: String) {
        guard article(id: articleID) != nil else { return }
        var progress = learningState.progressByArticleID[articleID] ?? HistoryArticleProgress()
        progress.lastOpenedAt = Date()
        progress.reviewCount += 1
        learningState.progressByArticleID[articleID] = progress
        addRecentArticle(articleID)
        persistProgress()
    }

    func toggleSectionCompleted(articleID: String, sectionID: String) {
        guard let article = article(id: articleID),
              article.sections.contains(where: { $0.id == sectionID }) else { return }
        var progress = learningState.progressByArticleID[articleID] ?? HistoryArticleProgress()
        if progress.completedSectionIDs.contains(sectionID) {
            progress.completedSectionIDs.remove(sectionID)
            progress.completedAt = nil
        } else {
            progress.completedSectionIDs.insert(sectionID)
            if article.sections.allSatisfy({ progress.completedSectionIDs.contains($0.id) }) {
                progress.completedAt = Date()
            }
        }
        learningState.progressByArticleID[articleID] = progress
        persistProgress()
    }

    func setCompleted(_ articleID: String, completed: Bool) {
        guard let article = article(id: articleID) else { return }
        var progress = learningState.progressByArticleID[articleID] ?? HistoryArticleProgress()
        if completed {
            progress.completedSectionIDs = Set(article.sections.map(\.id))
            progress.completedAt = Date()
        } else {
            progress.completedSectionIDs.removeAll()
            progress.completedAt = nil
        }
        learningState.progressByArticleID[articleID] = progress
        persistProgress()
    }

    func randomArticle(excluding articleID: String? = nil) -> HistoryArticle? {
        let candidates = articles.filter { $0.id != articleID }
        guard !candidates.isEmpty else { return nil }

        let unread = candidates.filter { !isCompleted($0.id) }
        let pool = unread.isEmpty ? candidates : unread
        guard let selected = pool.randomElement() else { return nil }

        learningState.lastRandomArticleID = selected.id
        addRecentArticle(selected.id)
        persistProgress()
        return selected
    }

    func reloadProgress() {
        let result = storageService.loadHistoryProgressResult()
        learningState = result.state
        canPersistProgress = !result.didFailToDecode
        if result.didFailToDecode {
            loadError = "历史学习进度文件无法读取，已保留原文件；清除所有数据后可重新建立进度。"
        } else if loadError == "历史学习进度文件无法读取，已保留原文件；清除所有数据后可重新建立进度。" {
            loadError = nil
        }
    }

    func resetProgress() {
        storageService.deleteHistoryProgress()
        learningState = HistoryLearningState()
        canPersistProgress = true
        if loadError == "历史学习进度文件无法读取，已保留原文件；清除所有数据后可重新建立进度。" {
            loadError = nil
        }
    }

    private func loadCatalogIfNeeded() {
        guard !didLoadCatalog else { return }
        didLoadCatalog = true

        guard let url = Bundle.main.url(forResource: "history_catalog", withExtension: "json") else {
            loadError = "未找到近代史科普内容资源 history_catalog.json。"
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let catalog = try JSONDecoder().decode(HistoryCatalog.self, from: data)
            if !catalog.note.isEmpty {
                catalogNote = catalog.note
            }
            let ids = catalog.articles.map(\.id)
            guard Set(ids).count == ids.count else {
                loadError = "历史科普目录包含重复的文章 ID，未加载该目录。"
                return
            }
            articles = catalog.articles.sorted { lhs, rhs in
                if lhs.startYear != rhs.startYear { return lhs.startYear < rhs.startYear }
                return lhs.title < rhs.title
            }
            loadError = nil
        } catch {
            loadError = "历史科普内容加载失败：\(error.localizedDescription)"
        }
    }

    private func addRecentArticle(_ articleID: String) {
        learningState.recentArticleIDs.removeAll { $0 == articleID }
        learningState.recentArticleIDs.insert(articleID, at: 0)
        if learningState.recentArticleIDs.count > 8 {
            learningState.recentArticleIDs = Array(learningState.recentArticleIDs.prefix(8))
        }
    }

    private func persistProgress() {
        let persistenceMessage = "历史学习进度保存失败，请检查本机数据目录权限。"
        guard canPersistProgress else {
            return
        }
        guard storageService.saveHistoryProgress(learningState) else {
            loadError = persistenceMessage
            return
        }
        if loadError == persistenceMessage {
            loadError = nil
        }
    }

    private static func normalizedSearchTerms(_ query: String) -> [String] {
        normalize(query)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ text: String) -> String {
        let separators = CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines)
            .union(.symbols)
        return text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
