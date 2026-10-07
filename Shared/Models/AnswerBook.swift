import Foundation

/// 答案之书里一条答案的性质。
///
/// 绝大多数是常规答案；另外两种是稀有条目，抽取概率极低，
/// 命中时会用不同视觉呈现，不会被误当成 bug。
enum AnswerBookKind: String, Codable, Hashable {
    /// 常规答案。
    case normal
    /// 稀有答案之一。
    case lost
    /// 稀有答案之一。
    case glitch
}

/// 答案之书的一条答案。`id` 沿用原始数据的编号，便于回溯。
struct AnswerBookEntry: Identifiable, Codable, Hashable {
    let id: Int
    let content: String
    let kind: AnswerBookKind

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case kind
    }

    init(id: Int, content: String, kind: AnswerBookKind = .normal) {
        self.id = id
        self.content = content
        self.kind = kind
    }

    /// `kind` 缺省为 `normal`：以后往资源文件里加字段时，旧条目仍能解码。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        kind = try container.decodeIfPresent(AnswerBookKind.self, forKey: .kind) ?? .normal
    }

    var isSpecial: Bool { kind != .normal }
}

/// 答案库资源文件（`Resources/answer_book.json`）的顶层结构。
struct AnswerBookCatalog: Codable {
    let version: String
    let note: String
    let answers: [AnswerBookEntry]

    private enum CodingKeys: String, CodingKey {
        case version
        case note
        case answers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "未知"
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        answers = try container.decodeIfPresent([AnswerBookEntry].self, forKey: .answers) ?? []
    }
}

/// 一次「测定」的记录。问题与答案都原样保留，便于回看。
struct AnswerBookRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let question: String
    /// 「换一个」会把这次测定的答案换成新的一条，因此答案相关的字段可变。
    var answer: String
    /// 命中答案在库中的 id，用于「换一个」排除当前条目。
    var entryID: Int
    var kind: AnswerBookKind
    let createdAt: Date
    var isFavorite: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case question
        case answer
        case entryID
        case kind
        case createdAt
        case isFavorite
    }

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        entryID: Int,
        kind: AnswerBookKind = .normal,
        createdAt: Date = Date(),
        isFavorite: Bool = false
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.entryID = entryID
        self.kind = kind
        self.createdAt = createdAt
        self.isFavorite = isFavorite
    }

    /// 全部字段都有默认值：老文件缺字段（比如将来新增的 `isFavorite`）也能读进来。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        answer = try container.decodeIfPresent(String.self, forKey: .answer) ?? ""
        entryID = try container.decodeIfPresent(Int.self, forKey: .entryID) ?? -1
        kind = try container.decodeIfPresent(AnswerBookKind.self, forKey: .kind) ?? .normal
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

/// 答案之书历史文件（`answerBookHistory.json`）的顶层结构。
///
/// 文件放在 `ManagedDataPath` 清单里，因此备份、统计与「清除所有数据」都会自动带上它。
struct AnswerBookHistoryState: Codable, Equatable {
    var schemaVersion: Int = 1
    /// 最新的一条在最前。
    var records: [AnswerBookRecord] = []
    /// 最近一次命中的答案 id，用于避免连续两次给出同一条。
    var lastEntryID: Int?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
        case lastEntryID
    }

    init(schemaVersion: Int = 1, records: [AnswerBookRecord] = [], lastEntryID: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.records = records
        self.lastEntryID = lastEntryID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        records = try container.decodeIfPresent([AnswerBookRecord].self, forKey: .records) ?? []
        lastEntryID = try container.decodeIfPresent(Int.self, forKey: .lastEntryID)
    }

    var favoriteRecords: [AnswerBookRecord] {
        records.filter(\.isFavorite)
    }
}
