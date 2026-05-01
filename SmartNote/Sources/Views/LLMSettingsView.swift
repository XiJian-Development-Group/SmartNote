import SwiftUI

struct LLMSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var config: LLMConfiguration
    @State private var isTesting = false
    @State private var testResult: String = ""
    @State private var showTestResult = false
    
    init() {
        _config = State(initialValue: LLMConfiguration())
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
                
                if config.provider.requiresAPIKey || config.provider == .lmstudio {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Token / API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("输入 Token 或 API Key", text: $config.apiKey)
                            .textFieldStyle(.roundedBorder)
                    }
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
            
            Section {
                HStack {
                    Button("测试连接") {
                        testConnection()
                    }
                    .disabled(isTesting || !config.enabled)
                    
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
        }
        .onChange(of: config) { newValue in
            appState.llmConfiguration = newValue
        }
        .alert("测试结果", isPresented: $showTestResult) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(testResult)
        }
    }
    
    private func testConnection() {
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
