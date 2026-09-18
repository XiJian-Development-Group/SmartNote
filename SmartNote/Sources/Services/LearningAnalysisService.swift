import Foundation
import AppKit

class LearningAnalysisService: ObservableObject {
    static let shared = LearningAnalysisService()
    
    @Published var isAnalyzing = false
    @Published var currentProfile: UserLearningProfile
    
    private var analysisTimer: Timer?
    private let storageService = StorageService()
    private var llmService: LLMService
    
    private init() {
        let config = StorageService().loadSettings().llmConfiguration
        self.llmService = LLMService(configuration: config)
        currentProfile = storageService.loadLearningProfile()
        setupAnalysisTimer()
    }
    
    func updateLLMService(_ service: LLMService) {
        self.llmService = service
    }
    
    private func setupAnalysisTimer() {
        analysisTimer?.invalidate()
        
        guard currentProfile.isEnabled, currentProfile.analysisFrequency != .never else {
            return
        }
        
        if let nextDate = currentProfile.nextAnalysisDate {
            let timeInterval = nextDate.timeIntervalSinceNow
            if timeInterval > 0 {
                analysisTimer = Timer.scheduledTimer(withTimeInterval: timeInterval, repeats: false) { [weak self] _ in
                    Task {
                        await self?.performAnalysis()
                    }
                }
            }
        }
    }
    
    func updateProfile(_ profile: UserLearningProfile) {
        var updatedProfile = profile
        updatedProfile.updateNextAnalysisDate()
        currentProfile = updatedProfile
        storageService.saveLearningProfile(updatedProfile)
        setupAnalysisTimer()
    }
    
    func setEnabled(_ enabled: Bool) {
        currentProfile.isEnabled = enabled
        currentProfile.updateNextAnalysisDate()
        storageService.saveLearningProfile(currentProfile)
        setupAnalysisTimer()
    }
    
    func setAnalysisFrequency(_ frequency: AnalysisFrequency) {
        currentProfile.analysisFrequency = frequency
        currentProfile.updateNextAnalysisDate()
        storageService.saveLearningProfile(currentProfile)
        setupAnalysisTimer()
    }
    
    func refreshNow() async {
        await performAnalysis()
    }
    
    func updatePreferences(_ preferences: LearningPreferences) {
        currentProfile.preferences = preferences
        storageService.saveLearningProfile(currentProfile)
    }
    
    func updateCharacteristics(_ characteristics: LearningCharacteristics) {
        currentProfile.characteristics = characteristics
        storageService.saveLearningProfile(currentProfile)
    }

    /// 本地启发式调优（不调 LLM）。把结果合并进当前 profile。
    @discardableResult
    func autoTuneLocally(mergeMode: LearningPreferenceAutoTuner.MergeMode = .fillMissing) -> LearningPreferenceAutoTuner.Suggestion {
        let tuner = LearningPreferenceAutoTuner(storage: storageService)
        let suggestion = tuner.generateSuggestion()
        var p = currentProfile
        tuner.applyAutoTuning(to: &p, suggestion: suggestion, mergeMode: mergeMode)
        currentProfile = p
        storageService.saveLearningProfile(p)
        return suggestion
    }
    
    private func performAnalysis() async {
        guard currentProfile.isEnabled else { return }
        
        let config = StorageService().loadSettings().llmConfiguration
        guard config.enabled else {
            await MainActor.run {
                isAnalyzing = false
            }
            return
        }
        
        let currentLLMService = LLMService(configuration: config)
        
        await MainActor.run {
            isAnalyzing = true
        }
        
        let materials = storageService.loadMaterials()
        let reviewPlans = storageService.loadReviewPlans()
        
        do {
            let prompt = buildAnalysisPrompt(materials: materials, reviewPlans: reviewPlans)
            
            var analysisResult = ""
            
            try await currentLLMService.sendMessageStreaming(system: "你是一个专业的学习分析师，请根据用户的学习数据进行分析并以JSON格式返回结果。", user: prompt) { chunk in
                analysisResult += chunk
            }
            
            if let parsedProfile = parseAnalysisResult(analysisResult) {
                await MainActor.run {
                    self.currentProfile.preferences = parsedProfile.preferences
                    self.currentProfile.characteristics = parsedProfile.characteristics
                    self.currentProfile.lastAnalysisDate = Date()
                    self.currentProfile.updateNextAnalysisDate()
                    self.storageService.saveLearningProfile(self.currentProfile)
                    self.setupAnalysisTimer()
                }
            }
        } catch {
            print("Analysis error: \(error)")
        }
        
        await MainActor.run {
            isAnalyzing = false
        }
    }
    
    private func buildAnalysisPrompt(materials: [StudyMaterial], reviewPlans: [ReviewPlan]) -> String {
        var prompt = "请分析以下用户学习数据，提取用户的学习偏好和特征，并以JSON格式返回结果：\n\n"
        
        prompt += "用户资料：\n"
        for material in materials.suffix(20) {
            prompt += "- \(material.name): \(material.content.prefix(200))\n"
        }
        
        prompt += "\n学习计划：\n"
        for plan in reviewPlans {
            prompt += "- \(plan.subject): 完成 \(plan.completedTasks)/\(plan.totalTasks) 个任务\n"
        }
        
        prompt += """
        
        请返回以下JSON格式（只需返回JSON，不要其他内容）：
        {
            "preferences": {
                "explanationStyle": "简洁|详细|举例说明|循序渐进",
                "difficulty": "简单|中等|困难",
                "exampleTypes": ["类比","练习","故事","图表","实际应用"],
                "languageTone": "专业|亲切|轻松|学术",
                "reviewMethod": "间隔重复|主动回忆|被动复习|混合",
                "attentionPoints": ["弱点1", "弱点2"],
                "weakSubjects": ["科目1"],
                "strongSubjects": ["科目2"]
            },
            "characteristics": {
                "preferredStudyTime": "早上|下午|晚上|深夜",
                "learningPace": "慢速|适中|快速",
                "memoryType": "视觉型|听觉型|动觉型|混合型",
                "noteTakingStyle": "大纲式|总结式|详细式|图表式|康奈尔式",
                "questionFrequency": "偶尔|一般|频繁",
                "errorPatterns": ["错误类型1"],
                "recentTopics": ["话题1"]
            }
        }
        """
        
        return prompt
    }
    
    private func parseAnalysisResult(_ result: String) -> (preferences: LearningPreferences, characteristics: LearningCharacteristics)? {
        guard let jsonStart = result.firstIndex(of: "{"),
              let jsonEnd = result.lastIndex(of: "}") else {
            return nil
        }
        
        let jsonString = String(result[jsonStart...jsonEnd])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefs = json["preferences"] as? [String: Any],
              let chars = json["characteristics"] as? [String: Any] else {
            return nil
        }
        
        var preferences = currentProfile.preferences
        if let style = prefs["explanationStyle"] as? String {
            preferences.preferredExplanationStyle = ExplanationStyle(rawValue: style) ?? .detailed
        }
        if let diff = prefs["difficulty"] as? String {
            preferences.preferredDifficulty = DifficultyLevel(rawValue: diff) ?? .medium
        }
        if let tone = prefs["languageTone"] as? String {
            preferences.preferredLanguageTone = LanguageTone(rawValue: tone) ?? .friendly
        }
        if let method = prefs["reviewMethod"] as? String {
            preferences.preferredReviewMethod = ReviewMethod(rawValue: method) ?? .spaced
        }
        if let examples = prefs["exampleTypes"] as? [String] {
            preferences.preferredExampleTypes = examples.compactMap { ExampleType(rawValue: $0) }
        }
        if let attention = prefs["attentionPoints"] as? [String] {
            preferences.attentionPoints = attention
        }
        if let weak = prefs["weakSubjects"] as? [String] {
            preferences.weakSubjects = weak
        }
        if let strong = prefs["strongSubjects"] as? [String] {
            preferences.strongSubjects = strong
        }
        
        var characteristics = currentProfile.characteristics
        if let time = chars["preferredStudyTime"] as? String {
            characteristics.preferredStudyTime = StudyTime(rawValue: time) ?? .evening
        }
        if let pace = chars["learningPace"] as? String {
            characteristics.learningPace = LearningPace(rawValue: pace) ?? .moderate
        }
        if let memory = chars["memoryType"] as? String {
            characteristics.memoryType = MemoryType(rawValue: memory) ?? .visual
        }
        if let notes = chars["noteTakingStyle"] as? String {
            characteristics.noteTakingStyle = NoteTakingStyle(rawValue: notes) ?? .summary
        }
        if let freq = chars["questionFrequency"] as? String {
            characteristics.questionFrequency = QuestionFrequency(rawValue: freq) ?? .medium
        }
        if let errors = chars["errorPatterns"] as? [String] {
            characteristics.errorPatterns = errors
        }
        if let topics = chars["recentTopics"] as? [String] {
            characteristics.recentTopics = topics
        }
        
        return (preferences, characteristics)
    }
    
    func buildEnhancedPrompt(basePrompt: String) -> String {
        guard currentProfile.isEnabled else { return basePrompt }
        
        let prefs = currentProfile.preferences
        let chars = currentProfile.characteristics
        
        var enhancedPrompt = basePrompt + "\n\n"
        
        enhancedPrompt += "用户学习偏好（请尽量满足）：\n"
        enhancedPrompt += "- 偏好讲解风格：\(prefs.preferredExplanationStyle.description)\n"
        enhancedPrompt += "- 偏好难度：\(prefs.preferredDifficulty.description)\n"
        enhancedPrompt += "- 偏好语言风格：\(prefs.preferredLanguageTone.description)\n"
        enhancedPrompt += "- 偏好复习方式：\(prefs.preferredReviewMethod.description)\n"
        
        if !prefs.preferredExampleTypes.isEmpty {
            let exampleTypes = prefs.preferredExampleTypes.map { $0.description }.joined(separator: "、")
            enhancedPrompt += "- 偏好例子类型：\(exampleTypes)\n"
        }
        
        if !prefs.weakSubjects.isEmpty {
            enhancedPrompt += "- 薄弱科目：\(prefs.weakSubjects.joined(separator: "、"))\n"
        }
        
        if !prefs.strongSubjects.isEmpty {
            enhancedPrompt += "- 擅长科目：\(prefs.strongSubjects.joined(separator: "、"))\n"
        }
        
        enhancedPrompt += "\n用户学习特征：\n"
        enhancedPrompt += "- 偏好学习时间：\(chars.preferredStudyTime.description)\n"
        enhancedPrompt += "- 学习节奏：\(chars.learningPace.description)\n"
        enhancedPrompt += "- 记忆类型：\(chars.memoryType.description)\n"
        enhancedPrompt += "- 笔记风格：\(chars.noteTakingStyle.description)\n"
        
        return enhancedPrompt
    }
}
