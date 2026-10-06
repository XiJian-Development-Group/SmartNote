import Foundation

enum HistoryPeriod: String, Codable, CaseIterable, Identifiable, Hashable {
    case earlyModern
    case lateQing
    case republic
    case antiJapaneseWar
    case postwar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .earlyModern: return "近代早期"
        case .lateQing: return "晚清变革"
        case .republic: return "民国与新文化"
        case .antiJapaneseWar: return "抗战与战争社会"
        case .postwar: return "战后重建与建国"
        }
    }

    /// 主题分组说明，不作为严格年份边界；跨时期文章仍可在相应主题下阅读。
    var shortName: String {
        switch self {
        case .earlyModern: return "战争、条约与洋务"
        case .lateQing: return "改革、革命与新政"
        case .republic: return "民国、社会与思想"
        case .antiJapaneseWar: return "局部抗战到全面抗战"
        case .postwar: return "战争结束与国家重建"
        }
    }
}

struct HistoryCatalog: Codable {
    let schemaVersion: Int
    let note: String
    let articles: [HistoryArticle]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case note
        case articles
    }

    init(schemaVersion: Int, note: String, articles: [HistoryArticle]) {
        self.schemaVersion = schemaVersion
        self.note = note
        self.articles = articles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        articles = try container.decodeIfPresent([HistoryArticle].self, forKey: .articles) ?? []
    }
}

struct HistoryArticle: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let period: HistoryPeriod
    let startYear: Int
    let endYear: Int?
    let tags: [String]
    let searchTerms: [String]
    let sections: [HistorySection]
    let keyEvents: [HistoryEvent]
    let keyFigures: [HistoryFigure]
    let glossary: [HistoryGlossaryEntry]
    let relatedArticleIDs: [String]
    let sources: [HistorySource]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case summary
        case period
        case startYear
        case endYear
        case tags
        case searchTerms
        case sections
        case keyEvents
        case keyFigures
        case glossary
        case relatedArticleIDs
        case sources
    }

    init(
        id: String,
        title: String,
        summary: String,
        period: HistoryPeriod,
        startYear: Int,
        endYear: Int?,
        tags: [String],
        searchTerms: [String] = [],
        sections: [HistorySection],
        keyEvents: [HistoryEvent] = [],
        keyFigures: [HistoryFigure] = [],
        glossary: [HistoryGlossaryEntry] = [],
        relatedArticleIDs: [String] = [],
        sources: [HistorySource]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.period = period
        self.startYear = startYear
        self.endYear = endYear
        self.tags = tags
        self.searchTerms = searchTerms
        self.sections = sections
        self.keyEvents = keyEvents
        self.keyFigures = keyFigures
        self.glossary = glossary
        self.relatedArticleIDs = relatedArticleIDs
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        period = try container.decode(HistoryPeriod.self, forKey: .period)
        startYear = try container.decode(Int.self, forKey: .startYear)
        endYear = try container.decodeIfPresent(Int.self, forKey: .endYear)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        searchTerms = try container.decodeIfPresent([String].self, forKey: .searchTerms) ?? []
        sections = try container.decodeIfPresent([HistorySection].self, forKey: .sections) ?? []
        keyEvents = try container.decodeIfPresent([HistoryEvent].self, forKey: .keyEvents) ?? []
        keyFigures = try container.decodeIfPresent([HistoryFigure].self, forKey: .keyFigures) ?? []
        glossary = try container.decodeIfPresent([HistoryGlossaryEntry].self, forKey: .glossary) ?? []
        relatedArticleIDs = try container.decodeIfPresent([String].self, forKey: .relatedArticleIDs) ?? []
        sources = try container.decodeIfPresent([HistorySource].self, forKey: .sources) ?? []
    }

    var yearLabel: String {
        guard let endYear else { return "\(startYear)" }
        return "\(startYear)—\(endYear)"
    }

    /// 详情页实际会展示的文字，用于估算阅读时长。
    private var displayedTextLength: Int {
        var length = title.count + summary.count
        for section in sections { length += section.title.count + section.bodyMarkdown.count }
        for event in keyEvents { length += event.title.count + event.detail.count + 4 }
        for figure in keyFigures { length += figure.name.count + figure.role.count + figure.contribution.count }
        for entry in glossary { length += entry.term.count + entry.definition.count }
        for source in sources { length += source.title.count + source.organization.count + source.note.count }
        return length
    }

    /// 预计阅读时长（分钟）。按正文实际字数推算，避免目录里的手写数字与内容长度脱节。
    /// 粗读中文约 300 字/分钟，取整后下限为 2 分钟。
    var readingMinutes: Int {
        max(2, Int((Double(displayedTextLength) / 300.0).rounded()))
    }

    var searchableText: String {
        ([title, summary] + tags + searchTerms
            + keyEvents.map { "\($0.year) \($0.title) \($0.detail)" }
            + keyFigures.map { "\($0.name) \($0.role)" }
            + glossary.map { "\($0.term) \($0.definition)" }
            + sections.map { "\($0.title) \($0.bodyMarkdown)" })
            .joined(separator: " ")
    }

    var readableText: String {
        ([title, summary] + sections.map { "\($0.title)\n\($0.bodyMarkdown)" })
            .joined(separator: "\n\n")
    }
}

struct HistorySection: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let bodyMarkdown: String
}

struct HistoryEvent: Codable, Identifiable, Hashable {
    let year: Int
    let title: String
    let detail: String

    var id: String { "\(year)-\(title)" }
}

struct HistoryFigure: Codable, Identifiable, Hashable {
    let name: String
    let role: String
    let contribution: String

    var id: String { name }
}

struct HistoryGlossaryEntry: Codable, Identifiable, Hashable {
    let term: String
    let definition: String

    var id: String { term }
}

struct HistorySource: Codable, Identifiable, Hashable {
    let title: String
    let organization: String
    let url: String
    let note: String

    var id: String { "\(organization)-\(title)-\(url)" }
}

struct HistoryLearningState: Codable, Equatable {
    var schemaVersion: Int = 1
    var progressByArticleID: [String: HistoryArticleProgress] = [:]
    var lastRandomArticleID: String?
    var recentArticleIDs: [String] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case progressByArticleID
        case lastRandomArticleID
        case recentArticleIDs
    }

    init(schemaVersion: Int = 1,
         progressByArticleID: [String: HistoryArticleProgress] = [:],
         lastRandomArticleID: String? = nil,
         recentArticleIDs: [String] = []) {
        self.schemaVersion = schemaVersion
        self.progressByArticleID = progressByArticleID
        self.lastRandomArticleID = lastRandomArticleID
        self.recentArticleIDs = recentArticleIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        progressByArticleID = try container.decodeIfPresent([String: HistoryArticleProgress].self, forKey: .progressByArticleID) ?? [:]
        lastRandomArticleID = try container.decodeIfPresent(String.self, forKey: .lastRandomArticleID)
        recentArticleIDs = try container.decodeIfPresent([String].self, forKey: .recentArticleIDs) ?? []
    }
}

struct HistoryArticleProgress: Codable, Equatable {
    var isFavorite: Bool = false
    var completedSectionIDs: Set<String> = []
    var lastOpenedAt: Date?
    var completedAt: Date?
    var reviewCount: Int = 0

    private enum CodingKeys: String, CodingKey {
        case isFavorite
        case completedSectionIDs
        case lastOpenedAt
        case completedAt
        case reviewCount
    }

    init(isFavorite: Bool = false,
         completedSectionIDs: Set<String> = [],
         lastOpenedAt: Date? = nil,
         completedAt: Date? = nil,
         reviewCount: Int = 0) {
        self.isFavorite = isFavorite
        self.completedSectionIDs = completedSectionIDs
        self.lastOpenedAt = lastOpenedAt
        self.completedAt = completedAt
        self.reviewCount = reviewCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        completedSectionIDs = try container.decodeIfPresent(Set<String>.self, forKey: .completedSectionIDs) ?? []
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        reviewCount = try container.decodeIfPresent(Int.self, forKey: .reviewCount) ?? 0
    }

    var isCompleted: Bool { completedAt != nil }
}
