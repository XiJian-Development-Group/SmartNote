import Foundation

class LLMService {
    private var configuration: LLMConfiguration
    
    init(configuration: LLMConfiguration = LLMConfiguration()) {
        self.configuration = configuration
    }
    
    func updateConfiguration(_ config: LLMConfiguration) {
        self.configuration = config
    }
    
    func isConfigured() -> Bool {
        return configuration.enabled && !configuration.modelID.isEmpty
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
        
        请用中文回复，格式清晰。
        """
        
        return try await sendMessage(system: systemPrompt, user: text)
    }
    
    func generateSummary(_ text: String) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let prompt = "请用简洁的中文总结以下内容的核心要点："
        return try await sendMessage(system: prompt, user: text)
    }
    
    func generateQuestions(_ text: String, count: Int = 5) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let prompt = "基于以下学习资料，生成 \(count) 道复习思考题或选择题："
        return try await sendMessage(system: prompt, user: text)
    }
    
    func explainConcept(_ concept: String, context: String? = nil) async throws -> String {
        guard isConfigured() else {
            throw LLMError.notConfigured
        }
        
        let contextText = context ?? "请解释这个概念"
        let prompt = "请详细解释以下概念，如果有必要可以结合例子说明："
        return try await sendMessage(system: prompt, user: concept)
    }
    
    private func sendMessage(system: String, user: String) async throws -> String {
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
            let result = try await sendMessage(system: "请用一句话回复测试成功", user: "你好")
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
        }
    }
}
