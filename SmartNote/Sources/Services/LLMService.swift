import Foundation

class LLMService {
    private var configuration: LLMConfiguration
    private var currentTask: Task<String, Error>?
    
    init(configuration: LLMConfiguration = LLMConfiguration()) {
        self.configuration = configuration
    }
    
    func updateConfiguration(_ config: LLMConfiguration) {
        self.configuration = config
    }
    
    func isConfigured() -> Bool {
        return configuration.enabled && !configuration.modelID.isEmpty
    }
    
    func cancelCurrentRequest() {
        currentTask?.cancel()
        currentTask = nil
    }
    
    func analyzeText(_ text: String, prompt: String? = nil) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let systemPrompt = prompt ?? """
        你是一个专业的学习助手。请分析以下学习资料，提取：
        1. 核心考点（最重要的知识点）
        2. 关键概念和定义
        3. 需要记忆的重点内容
        4. 可能的出题方向
        
        请用中文回复，格式清晰，使用 Markdown 格式。
        """
        
        return try await sendChatMessage(system: systemPrompt, user: text)
    }
    
    func generateSummary(_ text: String) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let prompt = "请用简洁的中文总结以下内容的核心要点："
        return try await sendChatMessage(system: prompt, user: text)
    }
    
    func generateQuestions(_ text: String, count: Int = 5) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let prompt = "基于以下学习资料，生成 \(count) 道复习思考题或选择题："
        return try await sendChatMessage(system: prompt, user: text)
    }
    
    func explainConcept(_ concept: String, context: String? = nil) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let contextText = context ?? "请解释这个概念"
        let prompt = "请详细解释以下概念，如果有必要可以结合例子说明："
        return try await sendChatMessage(system: prompt, user: concept)
    }
    
    func sendMessage(system: String, user: String) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let enhancedSystem = buildEnhancedPrompt(system)
        return try await sendChatMessage(system: enhancedSystem, user: user)
    }
    
    private func buildEnhancedPrompt(_ prompt: String) -> String {
        let profile = LearningAnalysisService.shared.currentProfile
        guard profile.isEnabled else { return prompt + customSystemPromptSuffix() }
        
        let prefs = profile.preferences
        var enhanced = prompt + "\n\n"
        
        enhanced += "【用户偏好提示】\n"
        enhanced += "- 讲解风格：\(prefs.preferredExplanationStyle.description)\n"
        enhanced += "- 难度：\(prefs.preferredDifficulty.description)\n"
        enhanced += "- 语言风格：\(prefs.preferredLanguageTone.description)\n"
        
        if !prefs.preferredExampleTypes.isEmpty {
            let examples = prefs.preferredExampleTypes.map { $0.description }.joined(separator: "、")
            enhanced += "- 例子类型：\(examples)\n"
        }
        
        if !prefs.weakSubjects.isEmpty {
            enhanced += "- 薄弱科目：\(prefs.weakSubjects.joined(separator: "、"))（需要更多解释）\n"
        }
        
        return enhanced + customSystemPromptSuffix()
    }
    
    private func customSystemPromptSuffix() -> String {
        let suffix = configuration.customSystemPromptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !suffix.isEmpty else { return "" }
        return "\n\n【用户自定义指令】\n" + suffix
    }
    
    func sendMessageStreaming(system: String, user: String, onChunk: @escaping (String) -> Void) async throws {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let enhancedSystem = buildEnhancedPrompt(system)
        
        switch configuration.provider {
        case .lmstudio:
            try await streamLMStudio(system: enhancedSystem, user: user, onChunk: onChunk)
        case .openai:
            try await streamOpenAI(system: enhancedSystem, user: user, onChunk: onChunk)
        case .anthropic:
            try await streamAnthropic(system: enhancedSystem, user: user, onChunk: onChunk)
        }
    }
    
    private func sendChatMessage(system: String, user: String) async throws -> String {
        switch configuration.provider {
        case .lmstudio:
            return try await callLMStudio(system: system, user: user)
        case .openai:
            return try await callOpenAI(system: system, user: user)
        case .anthropic:
            return try await callAnthropic(system: system, user: user)
        }
    }
    
    private func callLMStudio(system: String, user: String) async throws -> String {
        let url = URL(string: "\(configuration.baseURL)/v1/chat/completions")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseError
        }
        
        return content
    }
    
    private func streamLMStudio(system: String, user: String, onChunk: @escaping (String) -> Void) async throws {
        let url = URL(string: "\(configuration.baseURL)/v1/chat/completions")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens,
            "stream": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        
        var buffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let dataStr = String(line.dropFirst(6))
                
                if dataStr == "[DONE]" {
                    break
                }
                
                if let data = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    buffer += content
                    onChunk(content)
                }
            }
            
            try Task.checkCancellation()
        }
        
        if buffer.isEmpty {
            throw LLMError.parseError
        }
    }
    
    private func streamOpenAI(system: String, user: String, onChunk: @escaping (String) -> Void) async throws {
        let url = URL(string: "\(configuration.baseURL)/chat/completions")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens,
            "stream": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        
        var buffer = ""
        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let dataStr = String(line.dropFirst(6))
                
                if dataStr == "[DONE]" {
                    break
                }
                
                if let data = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    buffer += content
                    onChunk(content)
                }
            }
            
            try Task.checkCancellation()
        }
        
        if buffer.isEmpty {
            throw LLMError.parseError
        }
    }
    
    private func streamAnthropic(system: String, user: String, onChunk: @escaping (String) -> Void) async throws {
        let url = URL(string: "\(configuration.baseURL)/v1/messages")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let combinedText = "System: \(system)\n\nUser: \(user)"
        
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "user", "content": combinedText]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens,
            "stream": true
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw LLMError.parseError
        }
        
        for char in text {
            try Task.checkCancellation()
            onChunk(String(char))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    
    private func callOpenAI(system: String, user: String) async throws -> String {
        let url = URL(string: "\(configuration.baseURL)/chat/completions")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.parseError
        }
        
        return content
    }
    
    private func callAnthropic(system: String, user: String) async throws -> String {
        let url = URL(string: "\(configuration.baseURL)/v1/messages")!
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        
        let combinedText = "System: \(system)\n\nUser: \(user)"
        
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "user", "content": combinedText]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.maxTokens
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstBlock = content.first,
              let text = firstBlock["text"] as? String else {
            throw LLMError.parseError
        }
        
        return text
    }
    
    func testConnection() async -> (success: Bool, message: String) {
        guard configuration.enabled else {
            return (false, "LLM 功能未启用")
        }
        
        guard !configuration.modelID.isEmpty else {
            return (false, "未设置模型 ID")
        }
        
        do {
            let result = try await sendChatMessage(system: "请用一句话回复测试成功", user: "你好")
            return (true, "连接成功！\n\(result)")
        } catch let error as LLMError {
            return (false, error.localizedDescription)
        } catch {
            return (false, "连接失败: \(error.localizedDescription)")
        }
    }
}

enum LLMError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(statusCode: Int)
    case parseError
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LLM 未正确配置"
        case .invalidResponse:
            return "服务器响应无效"
        case .serverError(let statusCode):
            return "服务器错误 (状态码: \(statusCode))"
        case .parseError:
            return "解析响应失败"
        case .cancelled:
            return "请求已取消"
        }
    }
}
