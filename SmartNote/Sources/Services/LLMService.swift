import Foundation
import AppKit

/// 图片请求的纯逻辑判定。`.ocrFallback` 明确表示：图片不会进入请求体，
/// 只能先由本地 OCR 转成文本；只有 `.nativeVision` 才允许构造多模态载荷。
enum LLMImageRequestDecision: String, Equatable, Sendable {
    case textOnly
    case ocrFallback
    case nativeVision
    case blocked

    var sendsImagePayload: Bool {
        self == .nativeVision
    }

    var blockedMessage: String? {
        self == .blocked ? "当前 AI 服务不支持图像理解，未发送图片" : nil
    }

    static func make(
        hasImages: Bool,
        supportsImageUnderstanding: Bool,
        supportsNativeVision: Bool
    ) -> LLMImageRequestDecision {
        guard hasImages else { return .textOnly }
        guard supportsImageUnderstanding else { return .ocrFallback }
        return supportsNativeVision ? .nativeVision : .blocked
    }
}

struct LLMImageFallbackEvent: Sendable, Equatable {
    let imageCount: Int
    let message: String

    init(imageCount: Int) {
        self.imageCount = imageCount
        self.message = "图片已转为文本发送"
    }
}

class LLMService {
    private var configuration: LLMConfiguration
    private var currentTask: Task<String, Error>?
    private let ocrService: OCRService

    init(configuration: LLMConfiguration = LLMConfiguration(), ocrService: OCRService = OCRService()) {
        self.configuration = configuration
        self.ocrService = ocrService
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

    // MARK: - 多模态消息（OpenAI / Anthropic）

    /// 图片附件载荷：包含 base64 数据 + MIME
    struct ImagePayload: Sendable {
        let base64: String
        let mediaType: String   // "image/png" / "image/jpeg" / "image/webp" / "image/gif"
    }

    /// 多模态流式接口（图片+文本）。
    ///
    /// 当配置关闭图像理解时，这里不会进入任何 vision request builder：
    /// 先用本地 OCR 转成纯文本，再走普通文本 endpoint；OCR 失败则直接阻止请求。
    func sendMessageWithImagesStreaming(
        system: String,
        user: String,
        images: [ImagePayload],
        onImageFallback: ((LLMImageFallbackEvent) -> Void)? = nil,
        onChunk: @escaping (String) -> Void
    ) async throws {
        guard isConfigured() else { throw LLMError.notConfigured }

        let decision = LLMImageRequestDecision.make(
            hasImages: !images.isEmpty,
            supportsImageUnderstanding: configuration.supportsImageUnderstanding,
            supportsNativeVision: configuration.supportsNativeVision
        )
        let enhancedSystem = buildEnhancedPrompt(system)

        switch decision {
        case .textOnly:
            try await streamTextOnly(system: enhancedSystem, user: user, onChunk: onChunk)
        case .ocrFallback:
            let textPrompt = try await makeOCRTextPrompt(user: user, images: images)
            onImageFallback?(LLMImageFallbackEvent(imageCount: images.count))
            try await streamTextOnly(system: enhancedSystem, user: textPrompt, onChunk: onChunk)
        case .nativeVision:
            switch configuration.provider {
            case .openai:
                try await streamOpenAIVision(system: enhancedSystem, user: user, images: images, onChunk: onChunk)
            case .anthropic:
                try await streamAnthropicVision(system: enhancedSystem, user: user, images: images, onChunk: onChunk)
            case .lmstudio:
                throw LLMError.imageUnderstandingUnavailable
            }
        case .blocked:
            throw LLMError.imageUnderstandingUnavailable
        }
    }

    /// 多模态非流式（一次性返回），与流式接口使用同一套图像降级保险。
    func sendMessageWithImages(
        system: String,
        user: String,
        images: [ImagePayload],
        onImageFallback: ((LLMImageFallbackEvent) -> Void)? = nil
    ) async throws -> String {
        guard isConfigured() else { throw LLMError.notConfigured }

        let decision = LLMImageRequestDecision.make(
            hasImages: !images.isEmpty,
            supportsImageUnderstanding: configuration.supportsImageUnderstanding,
            supportsNativeVision: configuration.supportsNativeVision
        )
        let enhancedSystem = buildEnhancedPrompt(system)

        switch decision {
        case .textOnly:
            return try await sendChatMessage(system: enhancedSystem, user: user)
        case .ocrFallback:
            let textPrompt = try await makeOCRTextPrompt(user: user, images: images)
            onImageFallback?(LLMImageFallbackEvent(imageCount: images.count))
            return try await sendChatMessage(system: enhancedSystem, user: textPrompt)
        case .nativeVision:
            switch configuration.provider {
            case .openai:
                return try await callOpenAIVision(system: enhancedSystem, user: user, images: images)
            case .anthropic:
                return try await callAnthropicVision(system: enhancedSystem, user: user, images: images)
            case .lmstudio:
                throw LLMError.imageUnderstandingUnavailable
            }
        case .blocked:
            throw LLMError.imageUnderstandingUnavailable
        }
    }

    /// 便捷工具：把 NSImage/Image -> PNG/JPEG Data（带压缩 + 边长约束）
    /// - Returns: (data, mediaType)
    static func encodeForVision(_ image: NSImage, quality: Double, maxEdge: Int) -> (Data, String)? {
        guard let tiff = image.tiffRepresentation else { return nil }
        guard let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        // 缩放到最长边 maxEdge
        let originalSize = bitmap.size
        let scale: CGFloat
        if originalSize.width > originalSize.height {
            scale = CGFloat(maxEdge) / originalSize.width
        } else {
            scale = CGFloat(maxEdge) / originalSize.height
        }
        let target = scale < 1.0
            ? NSSize(width: originalSize.width * scale, height: originalSize.height * scale)
            : originalSize
        let resized = NSImage(size: target)
        resized.lockFocus()
        bitmap.draw(in: NSRect(origin: .zero, size: target),
                    from: NSRect(origin: .zero, size: originalSize),
                    operation: .copy,
                    fraction: 1.0,
                    respectFlipped: false,
                    hints: nil)
        resized.unlockFocus()
        guard let outTiff = resized.tiffRepresentation,
              let outBitmap = NSBitmapImageRep(data: outTiff) else { return nil }
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: max(0.1, min(1.0, quality))]
        guard let jpegData = outBitmap.representation(using: .jpeg, properties: props) else { return nil }
        return (jpegData, "image/jpeg")
    }
    
    /// 普通文本流式请求的单一分发点；OCR 降级也只走这里。
    private func streamTextOnly(system: String, user: String, onChunk: @escaping (String) -> Void) async throws {
        switch configuration.provider {
        case .lmstudio:
            try await streamLMStudio(system: system, user: user, onChunk: onChunk)
        case .openai:
            try await streamOpenAI(system: system, user: user, onChunk: onChunk)
        case .anthropic:
            try await streamAnthropic(system: system, user: user, onChunk: onChunk)
        }
    }

    /// 将所有图片在本地转成 OCR 文本；任何一张无法识别时都不发送请求。
    private func makeOCRTextPrompt(user: String, images: [ImagePayload]) async throws -> String {
        var recognizedBlocks: [String] = []

        for (index, image) in images.enumerated() {
            let recognized: String
            if let data = Data(base64Encoded: image.base64, options: [.ignoreUnknownCharacters]),
               let nsImage = NSImage(data: data) {
                recognized = await ocrService.recognizeText(from: nsImage)
            } else {
                recognized = ""
            }

            let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw LLMError.imageUnderstandingUnavailable
            }
            recognizedBlocks.append("图片 \(index + 1)（\(image.mediaType)）：\n\(trimmed)")
        }

        let question = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = question.isEmpty ? "请分析以下图片内容。" : question
        return """
        \(instruction)

        【本地 OCR 文本：图片未上传】
        \(recognizedBlocks.joined(separator: "\n\n"))
        """
    }

    /// 构造并校验 API 地址，避免非法服务器地址导致崩溃或发出相对路径请求。
    private func makeRequestURL(path: String) throws -> URL {
        let baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty else {
            throw LLMError.invalidURL
        }
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw LLMError.invalidURL
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            throw LLMError.invalidURL
        }
        return url
    }

    private func callLMStudio(system: String, user: String) async throws -> String {
        let url = try makeRequestURL(path: "/v1/chat/completions")
        
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
            "max_tokens": configuration.clampedMaxTokens
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
        let url = try makeRequestURL(path: "/v1/chat/completions")
        
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
            "max_tokens": configuration.clampedMaxTokens,
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
        let url = try makeRequestURL(path: "/chat/completions")
        
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
            "max_tokens": configuration.clampedMaxTokens,
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
        let url = try makeRequestURL(path: "/v1/messages")
        
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
            "max_tokens": configuration.clampedMaxTokens,
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
        let url = try makeRequestURL(path: "/chat/completions")
        
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
            "max_tokens": configuration.clampedMaxTokens
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
        let url = try makeRequestURL(path: "/v1/messages")
        
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
            "max_tokens": configuration.clampedMaxTokens
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

    // MARK: - OpenAI 多模态

    private func streamOpenAIVision(system: String, user: String, images: [LLMService.ImagePayload], onChunk: @escaping (String) -> Void) async throws {
        guard configuration.supportsImageUnderstanding,
              configuration.supportsNativeVision else {
            throw LLMError.imageUnderstandingUnavailable
        }
        let url = try makeRequestURL(path: "/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var contentArray: [[String: Any]] = [["type": "text", "text": user]]
        for img in images {
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:\(img.mediaType);base64,\(img.base64)"]
            ])
        }
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": contentArray]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.clampedMaxTokens,
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
                if dataStr == "[DONE]" { break }
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

    private func callOpenAIVision(system: String, user: String, images: [LLMService.ImagePayload]) async throws -> String {
        guard configuration.supportsImageUnderstanding,
              configuration.supportsNativeVision else {
            throw LLMError.imageUnderstandingUnavailable
        }
        let url = try makeRequestURL(path: "/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        var contentArray: [[String: Any]] = [["type": "text", "text": user]]
        for img in images {
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:\(img.mediaType);base64,\(img.base64)"]
            ])
        }
        let payload: [String: Any] = [
            "model": configuration.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": contentArray]
            ],
            "temperature": configuration.temperature,
            "max_tokens": configuration.clampedMaxTokens
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

    // MARK: - Anthropic 多模态

    private func streamAnthropicVision(system: String, user: String, images: [LLMService.ImagePayload], onChunk: @escaping (String) -> Void) async throws {
        guard configuration.supportsImageUnderstanding,
              configuration.supportsNativeVision else {
            throw LLMError.imageUnderstandingUnavailable
        }
        let url = try makeRequestURL(path: "/v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var contentArray: [[String: Any]] = []
        for img in images {
            contentArray.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": img.mediaType,
                    "data": img.base64
                ]
            ])
        }
        contentArray.append(["type": "text", "text": user])

        let payload: [String: Any] = [
            "model": configuration.modelID,
            "system": system,
            "messages": [["role": "user", "content": contentArray]],
            "temperature": configuration.temperature,
            "max_tokens": configuration.clampedMaxTokens,
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
                if dataStr == "[DONE]" { break }
                if let data = dataStr.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Anthropic 流式事件：{type:"content_block_delta", delta:{type:"text_delta", text:"..."}}
                    if let type = json["type"] as? String, type == "content_block_delta",
                       let delta = json["delta"] as? [String: Any],
                       let text = delta["text"] as? String {
                        buffer += text
                        onChunk(text)
                    }
                }
            }
            try Task.checkCancellation()
        }
        if buffer.isEmpty {
            throw LLMError.parseError
        }
    }

    private func callAnthropicVision(system: String, user: String, images: [LLMService.ImagePayload]) async throws -> String {
        guard configuration.supportsImageUnderstanding,
              configuration.supportsNativeVision else {
            throw LLMError.imageUnderstandingUnavailable
        }
        let url = try makeRequestURL(path: "/v1/messages")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var contentArray: [[String: Any]] = []
        for img in images {
            contentArray.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": img.mediaType,
                    "data": img.base64
                ]
            ])
        }
        contentArray.append(["type": "text", "text": user])

        let payload: [String: Any] = [
            "model": configuration.modelID,
            "system": system,
            "messages": [["role": "user", "content": contentArray]],
            "temperature": configuration.temperature,
            "max_tokens": configuration.clampedMaxTokens
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
              let content = json["content"] as? [[String: Any]] else {
            throw LLMError.parseError
        }
        let text = content.compactMap { block -> String? in
            if let t = block["type"] as? String, t == "text", let txt = block["text"] as? String {
                return txt
            }
            return nil
        }.joined()
        if text.isEmpty { throw LLMError.parseError }
        return text
    }
}

enum LLMError: LocalizedError {
    case notConfigured
    case invalidURL
    case imageUnderstandingUnavailable
    case invalidResponse
    case serverError(statusCode: Int)
    case parseError
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LLM 未正确配置"
        case .invalidURL:
            return "LLM 服务器地址无效，请填写有效的 http/https 地址"
        case .imageUnderstandingUnavailable:
            return "当前 AI 服务不支持图像理解，未发送图片"
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
