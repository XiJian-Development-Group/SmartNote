import Foundation

/// 本地启发式：根据现有 StudyMaterial 的关键词分布、WrongQuestion 错误模式
/// 与 ReviewPlan 完成度，给出"薄弱科目"、"近期话题"、"学习风格"建议。
///
/// 不调用 LLM，纯 Foundation，开销 < 1 ms；用于：
///   - 在 LLM 不可用时仍然给出学习画像
///   - 在每次 settings 保存时跑一遍，把"自动检测"开关开启的用户画像更新
final class LearningPreferenceAutoTuner {

    struct Suggestion {
        var weakSubjects: [String]           // 推荐的薄弱科目（高频出错的 key）
        var strongSubjects: [String]         // 推荐的擅长科目（少出错且常复习）
        var errorPatterns: [String]          // 错误模式关键词（如"计算粗心"）
        var recentTopics: [String]           // 最近的话题标签
        var suggestedMemoryType: MemoryType  // 推荐的学习记忆类型（视觉/听觉/...）
    }

    private let storage: StorageService

    init(storage: StorageService = StorageService()) {
        self.storage = storage
    }

    func generateSuggestion() -> Suggestion {
        let materials = storage.loadMaterials()
        let wrongQuestions = storage.loadWrongQuestions()
        let reviewPlans = storage.loadReviewPlans()
        let todoItems = storage.loadTodoItems()

        // 1. 关键词词频统计
        var topicFreq: [String: Int] = [:]
        for m in materials {
            for k in m.keywords ?? [] {
                topicFreq[k, default: 0] += 1
            }
            // 拆分类目标签用于无关键词时
            let cat = m.category.rawValue
            topicFreq["[\(cat)]", default: 0] += 1
        }

        // 2. 错题关键词
        var errorFreq: [String: Int] = [:]
        var weakSubjectFreq: [String: Int] = [:]
        for w in wrongQuestions {
            weakSubjectFreq[w.subject, default: 0] += 1
            for k in w.knowledgePoints {
                errorFreq[k, default: 0] += 1
            }
            // 把 errorReason 作为错误模式统计
            let trimmed = w.errorReason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                errorFreq[trimmed, default: 0] += 1
            }
        }

        // 3. 复习计划完成率
        var weakByPlan: [String: Double] = [:]   // subject -> (1 - completionRate)
        for p in reviewPlans where p.totalTasks > 0 {
            let rate = Double(p.completedTasks) / Double(p.totalTasks)
            if rate < 0.5 {
                weakByPlan[p.subject, default: 0] = 1.0 - rate
            }
        }

        // 合并薄弱科目：错误数 + 复习低完成率
        var combined: [String: Double] = [:]
        for (k, v) in weakSubjectFreq { combined[k, default: 0] += Double(v) }
        for (k, v) in weakByPlan { combined[k, default: 0] += v * 10 }

        let weakSubjects = combined
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }

        // 4. 擅长学科：高频出现 + 低错误率
        var strongByTopic: [String: Double] = [:]
        for (topic, freq) in topicFreq where freq >= 3 {
            strongByTopic[topic, default: 0] += Double(freq)
            if let err = combined[topic] {
                strongByTopic[topic, default: 0] -= err
            } else {
                strongByTopic[topic, default: 0] += 1.0
            }
        }
        let strongSubjects = strongByTopic
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }

        // 5. 最近话题：取最近 5 个材料的关键词
        let recent = materials.suffix(5).flatMap { $0.keywords ?? [] }
        var recentOrdered: [String] = []
        for t in recent where !recentOrdered.contains(t) { recentOrdered.append(t) }

        // 6. 错误模式：合并错题关键词
        let errorPatterns = errorFreq
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }

        // 7. 推荐记忆类型：依据资料里图片类 vs 其他类的比例（用 name 后缀推断）
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic"]
        let imageCount = materials.filter { m in
            let ext = (m.name as NSString).pathExtension.lowercased()
            return imageExts.contains(ext)
        }.count
        let textCount = materials.count - imageCount
        let suggestedMemoryType: MemoryType
        if Double(imageCount) > Double(textCount) * 0.4 {
            suggestedMemoryType = .visual
        } else if todoItems.count > materials.count / 3 {
            suggestedMemoryType = .kinesthetic
        } else if reviewPlans.isEmpty == false {
            suggestedMemoryType = .mixed
        } else {
            suggestedMemoryType = .visual
        }

        return Suggestion(
            weakSubjects: Array(weakSubjects),
            strongSubjects: Array(strongSubjects),
            errorPatterns: Array(errorPatterns),
            recentTopics: Array(recentOrdered.prefix(8)),
            suggestedMemoryType: suggestedMemoryType
        )
    }

    /// 把 Suggestion 合并进已有 UserLearningProfile（保留用户手动填的偏好，只更新空值或追加补全）
    func applyAutoTuning(to profile: inout UserLearningProfile, suggestion: Suggestion, mergeMode: MergeMode = .fillMissing) {
        switch mergeMode {
        case .fillMissing:
            if profile.preferences.weakSubjects.isEmpty {
                profile.preferences.weakSubjects = suggestion.weakSubjects
            }
            if profile.preferences.strongSubjects.isEmpty {
                profile.preferences.strongSubjects = suggestion.strongSubjects
            }
            if profile.characteristics.recentTopics.isEmpty {
                profile.characteristics.recentTopics = suggestion.recentTopics
            }
            if profile.characteristics.errorPatterns.isEmpty {
                profile.characteristics.errorPatterns = suggestion.errorPatterns
            }
        case .overwrite:
            profile.preferences.weakSubjects = suggestion.weakSubjects
            profile.preferences.strongSubjects = suggestion.strongSubjects
            profile.characteristics.recentTopics = suggestion.recentTopics
            profile.characteristics.errorPatterns = suggestion.errorPatterns
        }
        // 视觉型作为初始推荐；用户仍可在 UI 切
        profile.characteristics.memoryType = suggestion.suggestedMemoryType
    }

    enum MergeMode {
        case fillMissing   // 仅补缺失字段
        case overwrite     // 强制覆盖
    }
}
