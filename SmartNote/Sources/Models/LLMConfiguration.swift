import Foundation

struct LLMConfiguration: Codable, Equatable {
    var enabled: Bool = false
    var provider: LLMProvider = .lmstudio
    var serverURL: String = "http://localhost:1234"
    var apiKey: String = ""
    var modelID: String = ""
    var temperature: Double = 0.7
    var maxTokens: Int = 2048
    var supportsImageUnderstanding: Bool = false
    var customSystemPromptSuffix: String = ""
    
    var displayName: String {
        switch provider {
        case .lmstudio:
            return "LM Studio"
        case .openai:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        }
    }
    
    var baseURL: String {
        switch provider {
        case .lmstudio:
            return serverURL
        case .openai:
            return serverURL.isEmpty ? "https://api.openai.com/v1" : serverURL
        case .anthropic:
            return serverURL.isEmpty ? "https://api.anthropic.com" : serverURL
        }
    }
}

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case lmstudio = "lmstudio"
    case openai = "openai"
    case anthropic = "anthropic"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .lmstudio:
            return "LM Studio (推荐)"
        case .openai:
            return "OpenAI API"
        case .anthropic:
            return "Anthropic API (不推荐)"
        }
    }
    
    var description: String {
        switch self {
        case .lmstudio:
            return "本地 LLM 服务器，支持 GGUF 与 MLX 模型"
        case .openai:
            return "OpenAI 兼容 API"
        case .anthropic:
            return "Claude 系列模型，需付费使用"
        }
    }
    
    var defaultPort: String {
        switch self {
        case .lmstudio:
            return "1234"
        case .openai:
            return "443"
        case .anthropic:
            return "443"
        }
    }
    
    var requiresAPIKey: Bool {
        switch self {
        case .lmstudio:
            return false
        case .openai:
            return true
        case .anthropic:
            return true
        }
    }
    
    var defaultModel: String {
        switch self {
        case .lmstudio:
            return "lfm2.5-1.2B"
        case .openai:
            return "gpt-3.5-turbo"
        case .anthropic:
            return "claude-3-haiku-20240307"
        }
    }
}
