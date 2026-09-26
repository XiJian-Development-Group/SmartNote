import Foundation
import CryptoKit

/// LLM 服务配置。
///
/// `apiKey` 仍然保留在内存模型中供 LLMService 使用，但自定义编码器永远不会把它写入
/// JSON。StorageService 负责将它写入登录钥匙串，并在加载时注入。
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
    /// 图片压缩质量（0...1）；上传前会先把图片压到此阈值对应的最大边长 → JPEG。
    var visionImageQuality: Double = 0.85
    /// 上传前把图片的较长边缩到不超过此 px。
    var visionImageMaxEdge: Int = 1280
    /// 单次请求允许附带图片数上限（>1 时按 base64 内联）
    var visionMaxImages: Int = 1

    /// 用户明确确认过的规范化服务地址。官方服务和本地回环地址不需要此字段。
    /// 用地址而不是布尔值记录信任，可避免用户改 URL 后沿用旧主机的授权。
    var trustedServerURL: String = ""

    /// 保留旧的成员式初始化器参数顺序；新字段放在末尾并带默认值。
    init(
        enabled: Bool = false,
        provider: LLMProvider = .lmstudio,
        serverURL: String = "http://localhost:1234",
        apiKey: String = "",
        modelID: String = "",
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        supportsImageUnderstanding: Bool = false,
        customSystemPromptSuffix: String = "",
        visionImageQuality: Double = 0.85,
        visionImageMaxEdge: Int = 1280,
        visionMaxImages: Int = 1,
        trustedServerURL: String = ""
    ) {
        self.enabled = enabled
        self.provider = provider
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.modelID = modelID
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.supportsImageUnderstanding = supportsImageUnderstanding
        self.customSystemPromptSuffix = customSystemPromptSuffix
        self.visionImageQuality = visionImageQuality
        self.visionImageMaxEdge = visionImageMaxEdge
        self.visionMaxImages = visionMaxImages
        self.trustedServerURL = trustedServerURL
    }

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

    /// 当前 provider 是否原生支持图片（OpenAI / Anthropic 兼容多模态 endpoint）
    var supportsNativeVision: Bool {
        switch provider {
        case .openai, .anthropic: return true
        case .lmstudio: return false
        }
    }

    // MARK: - 地址安全与钥匙串标识

    /// 用于比较、信任确认和钥匙串账号的稳定地址表示。
    /// 只规范化 scheme/host、去掉 fragment 与根路径末尾斜杠，不改变查询参数或路径语义。
    var normalizedServerURL: String {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw) else {
            return raw
        }

        if let scheme = components.scheme {
            components.scheme = scheme.lowercased()
        }
        if let host = components.host {
            components.host = host.lowercased()
        }
        components.fragment = nil
        // P3-5 query 不参与「这是不是同一个服务」的判定：
        // 用户在地址后加 ?debug=1 会让 normalizedServerURL 变化，
        // 导致 trustedServerURL 突然失配、被迫重新确认信任。
        // 信任只由 scheme/host/port/path 决定。
        components.query = nil
        components.queryItems = nil

        var path = components.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path == "/" ? "" : path

        return components.url?.absoluteString ?? raw
    }

    /// 把 maxTokens 夹到本应用支持的区间。
    /// P3-9：用户可能把值设成 4096 而本地模型只支持 2048，
    /// 由服务端截断或报错，报错信息又很难懂。这里在进入请求前就夹住。
    static let supportedMaxTokensRange: ClosedRange<Int> = 256...4096
    var clampedMaxTokens: Int {
        min(max(maxTokens, Self.supportedMaxTokensRange.lowerBound),
            Self.supportedMaxTokensRange.upperBound)
    }

    /// 解析后的主机名（小写），供 UI 警告和地址判断使用。
    var serverHost: String? {
        guard let components = URLComponents(string: normalizedServerURL),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        return host
    }

    /// 是否是应用已知的官方 API 主机。仅 HTTPS、无非标准端口时视为官方地址。
    var isOfficialServiceURL: Bool {
        guard let components = URLComponents(string: normalizedServerURL),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        if let port = components.port, port != 443 {
            return false
        }
        return Self.isOfficialHost(host, for: provider)
    }

    private static func isOfficialHost(_ host: String, for provider: LLMProvider) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        switch provider {
        case .openai:
            return normalizedHost == "api.openai.com"
        case .anthropic:
            return normalizedHost == "api.anthropic.com"
        case .lmstudio:
            return false
        }
    }

    /// 回环地址视为本地服务；HTTP 回环连接不需要额外的远程服务确认。
    var isLocalServiceURL: Bool {
        guard let components = URLComponents(string: normalizedServerURL),
              let host = components.host?.lowercased() else {
            return false
        }
        return Self.isLoopbackHost(host)
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        if normalizedHost == "localhost" || normalizedHost == "::1" {
            return true
        }
        // 只接受合法的 127.0.0.0/8 IPv4 回环地址；不能把 127.example.com
        // 这类普通第三方主机误判成本地服务。
        let octets = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else {
            return false
        }
        return octets.allSatisfy { octet in
            guard let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }

    /// 非官方、非回环服务需要用户明确确认；无效地址也视为不可保存。
    var requiresServerTrustConfirmation: Bool {
        guard isValidServerURL else { return true }
        return !isOfficialServiceURL && !isLocalServiceURL
    }

    /// 当前地址是否满足 UI 的安全保存/测试前置条件。
    var canSaveSafely: Bool {
        isValidServerURL && isServerTrusted
    }

    var isValidServerURL: Bool {
        guard let components = URLComponents(string: normalizedServerURL),
              components.url != nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        return true
    }

    var isInsecureRemoteHTTP: Bool {
        guard let components = URLComponents(string: normalizedServerURL),
              components.scheme?.lowercased() == "http" else {
            return false
        }
        return !isLocalServiceURL
    }

    /// 绑定到具体地址的信任状态：改 URL 后旧确认不会自动沿用。
    var isServerTrusted: Bool {
        guard isValidServerURL else { return false }
        return !requiresServerTrustConfirmation || trustedServerURL == normalizedServerURL
    }

    /// UI 使用的安全提示；官方与本地服务不显示额外警告。
    var serverSecurityWarning: String? {
        guard isValidServerURL, let host = serverHost else {
            return "服务器地址无效：需要有效的 http/https 地址和主机名。"
        }
        if isLocalServiceURL {
            return nil
        }

        var parts: [String] = []
        if isInsecureRemoteHTTP {
            parts.append("HTTP 明文连接：API key 将以未加密方式发送到 \(host)，建议仅本地服务使用 HTTP。")
        }
        if !isOfficialServiceURL {
            parts.append("第三方服务：你的 API key 将发送到 \(host)。")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// 每个 provider + 规范化服务地址使用独立的 Keychain account，避免不同配置互相覆盖。
    /// 这里只把摘要放进 account，不会把 API key 写入 account。
    var keychainAccount: String {
        let material = "\(provider.rawValue)|\(normalizedServerURL)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "llm-api-key|\(provider.rawValue)|\(hex)"
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case enabled
        case provider
        case serverURL
        // 只为读取旧 settings.json；encode(to:) 会明确跳过它。
        case apiKey
        case modelID
        case temperature
        case maxTokens
        case supportsImageUnderstanding
        case customSystemPromptSuffix
        case visionImageQuality
        case visionImageMaxEdge
        case visionMaxImages
        case trustedServerURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = try container.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? .lmstudio
        serverURL = try container.decodeIfPresent(String.self, forKey: .serverURL) ?? "http://localhost:1234"
        // 兼容旧版本：旧文件中的 key 只在内存中短暂存在，StorageService 会负责迁移。
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 2048
        supportsImageUnderstanding = try container.decodeIfPresent(Bool.self, forKey: .supportsImageUnderstanding) ?? false
        customSystemPromptSuffix = try container.decodeIfPresent(String.self, forKey: .customSystemPromptSuffix) ?? ""
        visionImageQuality = try container.decodeIfPresent(Double.self, forKey: .visionImageQuality) ?? 0.85
        visionImageMaxEdge = try container.decodeIfPresent(Int.self, forKey: .visionImageMaxEdge) ?? 1280
        visionMaxImages = try container.decodeIfPresent(Int.self, forKey: .visionMaxImages) ?? 1
        trustedServerURL = try container.decodeIfPresent(String.self, forKey: .trustedServerURL) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(provider, forKey: .provider)
        try container.encode(serverURL, forKey: .serverURL)
        // 重要：绝不编码 apiKey，防止 settings.json 和未加密备份泄露凭据。
        try container.encode(modelID, forKey: .modelID)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(supportsImageUnderstanding, forKey: .supportsImageUnderstanding)
        try container.encode(customSystemPromptSuffix, forKey: .customSystemPromptSuffix)
        try container.encode(visionImageQuality, forKey: .visionImageQuality)
        try container.encode(visionImageMaxEdge, forKey: .visionImageMaxEdge)
        try container.encode(visionMaxImages, forKey: .visionMaxImages)
        try container.encode(trustedServerURL, forKey: .trustedServerURL)
    }
}

enum LLMProvider: String, Codable, CaseIterable, Identifiable {
    case lmstudio = "lmstudio"
    case openai = "openai"
    case anthropic = "anthropic"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .lmstudio: return "LM Studio (推荐)"
        case .openai: return "OpenAI API"
        case .anthropic: return "Anthropic API (不推荐)"
        }
    }
    
    var description: String {
        switch self {
        case .lmstudio: return "本地 LLM 服务器，支持 GGUF 与 MLX 模型"
        case .openai: return "OpenAI 兼容 API"
        case .anthropic: return "Claude 系列模型，需付费使用"
        }
    }
    
    var defaultPort: String {
        switch self {
        case .lmstudio: return "1234"
        case .openai: return "443"
        case .anthropic: return "443"
        }
    }
    
    var requiresAPIKey: Bool {
        switch self {
        case .lmstudio: return false
        case .openai: return true
        case .anthropic: return true
        }
    }
    
    var defaultModel: String {
        switch self {
        case .lmstudio: return "lfm2.5-1.2B"
        case .openai: return "gpt-3.5-turbo"
        case .anthropic: return "claude-3-haiku-20240307"
        }
    }
}
