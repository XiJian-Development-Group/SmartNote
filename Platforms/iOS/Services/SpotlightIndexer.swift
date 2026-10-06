import Foundation
import CoreSpotlight
import SwiftUI

@MainActor
class SpotlightIndexer: ObservableObject {
    static let shared = SpotlightIndexer()

    private let index = CSSearchableIndex.default()
    private let domainIdentifier = "com.skyc8266.smartnote.ios"

    private init() {}

    func indexAll(materials: [StudyMaterial], diaries: [DiaryEntry], wrongQuestions: [WrongQuestion]) {
        var items: [CSSearchableItem] = []

        // 索引资料
        for material in materials {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .data)
            attributeSet.title = material.name
            attributeSet.contentDescription = material.content.prefix(200).description
            attributeSet.keywords = material.keywords ?? []
            attributeSet.creator = "SmartNote"
            attributeSet.contentType = material.type.utiType.identifier

            let item = CSSearchableItem(
                uniqueIdentifier: "material_\(material.id.uuidString)",
                domainIdentifier: domainIdentifier,
                attributeSet: attributeSet
            )
            item.expirationDate = Date.distantFuture
            items.append(item)
        }

        // 索引日记
        for diary in diaries {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .plainText)
            attributeSet.title = diary.title.isEmpty ? "无标题日记" : diary.title
            attributeSet.contentDescription = diary.content.prefix(200).description
            attributeSet.keywords = diaryIndexKeywords(diary)
            attributeSet.creator = "SmartNote"
            attributeSet.contentCreationDate = diary.createdAt
            attributeSet.contentModificationDate = diary.updatedAt

            let item = CSSearchableItem(
                uniqueIdentifier: "diary_\(diary.id.uuidString)",
                domainIdentifier: domainIdentifier,
                attributeSet: attributeSet
            )
            item.expirationDate = Date.distantFuture
            items.append(item)
        }

        // 索引错题
        for question in wrongQuestions {
            let attributeSet = CSSearchableItemAttributeSet(contentType: .plainText)
            attributeSet.title = "错题 · \(question.subject)"
            attributeSet.contentDescription = question.questionContent.prefix(200).description
            attributeSet.keywords = question.knowledgePoints
            attributeSet.creator = "SmartNote"

            let item = CSSearchableItem(
                uniqueIdentifier: "wrongQuestion_\(question.id.uuidString)",
                domainIdentifier: domainIdentifier,
                attributeSet: attributeSet
            )
            item.expirationDate = Date.distantFuture
            items.append(item)
        }

        // 批量索引
        index.indexSearchableItems(items) { error in
            if let error = error {
                print("Spotlight 索引失败：\(error)")
            } else {
                print("Spotlight 索引成功：\(items.count) 项")
            }
        }
    }

    func indexMaterial(_ material: StudyMaterial) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .data)
        attributeSet.title = material.name
        attributeSet.contentDescription = material.content.prefix(200).description
        attributeSet.keywords = material.keywords ?? []
        attributeSet.creator = "SmartNote"
        attributeSet.contentType = material.type.utiType.identifier

        let item = CSSearchableItem(
            uniqueIdentifier: "material_\(material.id.uuidString)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Date.distantFuture

        index.indexSearchableItems([item]) { error in
            if let error = error { print("索引资料失败：\(error)") }
        }
    }

    func indexDiary(_ diary: DiaryEntry) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .plainText)
        attributeSet.title = diary.title.isEmpty ? "无标题日记" : diary.title
        attributeSet.contentDescription = diary.content.prefix(200).description
        attributeSet.keywords = diaryIndexKeywords(diary)
        attributeSet.creator = "SmartNote"
        attributeSet.contentCreationDate = diary.createdAt
        attributeSet.contentModificationDate = diary.updatedAt

        let item = CSSearchableItem(
            uniqueIdentifier: "diary_\(diary.id.uuidString)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Date.distantFuture

        index.indexSearchableItems([item]) { error in
            if let error = error { print("索引日记失败：\(error)") }
        }
    }

    func indexWrongQuestion(_ question: WrongQuestion) {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .plainText)
        attributeSet.title = "错题 · \(question.subject)"
        attributeSet.contentDescription = question.questionContent.prefix(200).description
        attributeSet.keywords = question.knowledgePoints
        attributeSet.creator = "SmartNote"

        let item = CSSearchableItem(
            uniqueIdentifier: "wrongQuestion_\(question.id.uuidString)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet
        )
        item.expirationDate = Date.distantFuture

        index.indexSearchableItems([item]) { error in
            if let error = error { print("索引错题失败：\(error)") }
        }
    }

    /// 日记的可搜索关键词。
    ///
    /// `DiaryEntry` 没有独立的 `tags` 字段，因此用分类名加上"是否含图片/白板"
    /// 这类可检索特征作为关键词，保证用户在 Spotlight 里按分类也能搜到。
    private func diaryIndexKeywords(_ diary: DiaryEntry) -> [String] {
        var keywords = [diary.category]
        if !diary.imagePaths.isEmpty { keywords.append("图片") }
        if diary.whiteboardID != nil { keywords.append("白板") }
        if !diary.linkedMaterialIDs.isEmpty { keywords.append("关联资料") }
        return keywords.filter { !$0.isEmpty }
    }

    func deleteMaterial(_ materialID: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["material_\(materialID.uuidString)"]) { error in
            if let error = error { print("删除资料索引失败：\(error)") }
        }
    }

    func deleteDiary(_ diaryID: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["diary_\(diaryID.uuidString)"]) { error in
            if let error = error { print("删除日记索引失败：\(error)") }
        }
    }

    func deleteWrongQuestion(_ questionID: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["wrongQuestion_\(questionID.uuidString)"]) { error in
            if let error = error { print("删除错题索引失败：\(error)") }
        }
    }

    func deleteAll() {
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error = error { print("删除所有索引失败：\(error)") }
        }
    }

    // 处理 Spotlight 搜索点击
    func handleSpotlightSelection(_ userActivity: NSUserActivity) -> (type: String, id: UUID)? {
        guard userActivity.activityType == CSSearchableItemActionType,
              let uniqueIdentifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
            return nil
        }

        let components = uniqueIdentifier.split(separator: "_")
        guard components.count == 2,
              let id = UUID(uuidString: String(components[1])) else { return nil }

        return (String(components[0]), id)
    }
}

// UTType 扩展
import UniformTypeIdentifiers

extension MaterialType {
    var utiType: UTType {
        switch self {
        case .pdf: return .pdf
        case .word: return UTType(filenameExtension: "docx") ?? .data
        case .powerpoint: return UTType(filenameExtension: "pptx") ?? .data
        case .image: return .image
        case .text: return .plainText
        case .markdown: return UTType(filenameExtension: "md") ?? .plainText
        case .document: return .data
        case .video: return .movie
        case .audio: return .audio
        case .other: return .data
        }
    }
}