import SwiftUI

struct LLMSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var config: LLMConfiguration
    @State private var isTesting = false
    @State private var testResult: String = ""
    @State private var showTestResult = false
    @State private var settingsPersistenceError: String?

    init() {
        _config = State(initialValue: LLMConfiguration())
    }

    /// 配置里已记录的受信任地址。当前地址与它不一致时，
    /// 说明用户之前信任过别的地址，可以选择是否一键沿用。
    private var previouslyTrustedServerURL: String? {
        let stored = config.trustedServerURL
        return stored.isEmpty ? nil : stored
    }

    private static func displayHost(_ urlString: String) -> String {
        let components = URLComponents(string: urlString)
        if let host = components?.host, let port = components?.port {
            return "\(host):\(port)"
        }
        return components?.host ?? urlString
    }

    var body: some View {
        Form {
            Section {
                Toggle("启用 AI 分析功能", isOn: $config.enabled)
            }

            Section("AI 提供商") {
                Picker("选择提供商", selection: $config.provider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Text(config.provider.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("服务器配置") {
                HStack {
                    Text("服务器地址")
                    Spacer()
                    TextField("http://localhost:1234", text: $config.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }

                HStack {
                    Text("模型 ID")
                    Spacer()
                    TextField(config.provider.defaultModel, text: $config.modelID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                }

                if let warning = config.serverSecurityWarning {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if config.requiresServerTrustConfirmation && config.isValidServerURL {
                            Toggle("我信任此服务", isOn: Binding(
                                get: { config.isServerTrusted },
                                set: { isTrusted in
                                    config.trustedServerURL = isTrusted ? config.normalizedServerURL : ""
                                }
                            ))
                            if !config.isServerTrusted {
                                Text("保存或测试连接前，请先确认 API key 会发送到此服务。")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                // 信任是绑定到地址的：把 URL 改一下再改回来，
                                // 旧确认不会自动沿用。这里明确告诉用户可以一键沿用。
                                if let previous = previouslyTrustedServerURL,
                                   previous != config.normalizedServerURL {
                                    HStack(spacing: 8) {
                                        Text("你之前信任过 \(Self.displayHost(previous))，是否沿用该信任？")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        Button("沿用") {
                                            config.trustedServerURL = previous
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                if config.provider.requiresAPIKey || config.provider == .lmstudio {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token / API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("输入 Token 或 API Key", text: $config.apiKey)
                            .textFieldStyle(.roundedBorder)
                        Text("API key 保存在 macOS 登录钥匙串，不会写入 settings.json 或新生成的未加密备份。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if let settingsPersistenceError {
                    Label(settingsPersistenceError, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("生成参数") {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Slider(value: $config.temperature, in: 0...1, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.1f", config.temperature))
                        .frame(width: 30)
                }

                Stepper("最大 Token 数: \(config.maxTokens)", value: $config.maxTokens, in: 256...4096, step: 256)
            }

            Section("图像理解") {
                Toggle("AI 服务器支持图像理解", isOn: $config.supportsImageUnderstanding)

                if !config.supportsImageUnderstanding {
                    Text("关闭后，图片将被转换为文本发送（可能存在识别误差）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("自定义系统提示词后缀") {
                Text("该内容将追加到每次 AI 请求的系统提示词末尾，可用于指定回复风格、格式要求等。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $config.customSystemPromptSuffix)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)

                Text("示例：\"请始终用中文回复\" 或 \"请使用简短直接的回答\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Button("测试连接") {
                        testConnection()
                    }
                    .disabled(isTesting || !config.enabled || !config.canSaveSafely)

                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                    }

                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            config = appState.llmConfiguration
            settingsPersistenceError = StorageService.settingsPersistenceError
        }
        .onChange(of: config) { newValue in
            // 未确认的第三方/HTTP 远端地址只保留在编辑状态，不能写入 settings，
            // 也不能被测试按钮使用。
            guard newValue.canSaveSafely else { return }
            settingsPersistenceError = nil
            appState.llmConfiguration = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageSettingsPersistenceIssue)) { notification in
            settingsPersistenceError = notification.userInfo?["message"] as? String
                ?? StorageService.settingsPersistenceError
        }
        .alert("测试结果", isPresented: $showTestResult) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(testResult)
        }
    }

    private func testConnection() {
        guard config.canSaveSafely else {
            testResult = config.isValidServerURL
                ? "请先确认你信任此服务，再测试连接。"
                : "请先填写有效的服务器地址。"
            showTestResult = true
            return
        }
        guard config.enabled else {
            testResult = "请先启用 AI 分析功能。"
            showTestResult = true
            return
        }

        isTesting = true
        appState.llmConfiguration = config

        Task {
            let result = await appState.llmService.testConnection()
            await MainActor.run {
                testResult = result.message
                showTestResult = true
                isTesting = false
            }
        }
    }
}
