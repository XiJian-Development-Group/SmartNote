import SwiftUI

struct AIChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var userMessage = ""
    @State private var messages: [ChatMessage] = []
    @State private var isSending = false
    @State private var showSettings = false
    @State private var currentStreamingID: UUID?
    @State private var streamingContent = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            inputView
        }
        .sheet(isPresented: $showSettings) {
            LLMSettingsView()
                .environmentObject(appState)
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 对话")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("与 AI 助手交流学习问题")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isSending {
                Button {
                    cancelCurrentRequest()
                } label: {
                    Label("取消", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            
            if !appState.llmConfiguration.enabled {
                Button {
                    showSettings = true
                } label: {
                    Label("配置 AI", systemImage: "gear")
                }
                .buttonStyle(.bordered)
            }
            
            Button {
                messages.removeAll()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var inputView: some View {
        HStack(spacing: 12) {
            if !appState.llmConfiguration.enabled {
                VStack(alignment: .leading) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("请先在设置中启用 AI")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            TextField("输入问题...", text: $userMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(!appState.llmConfiguration.enabled || isSending)
            
            Button {
                sendMessage()
            } label: {
                if isSending {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(userMessage.isEmpty || !appState.llmConfiguration.enabled || isSending)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func sendMessage() {
        guard !userMessage.isEmpty else { return }
        
        let userMsg = ChatMessage(id: UUID(), role: .user, content: userMessage)
        messages.append(userMsg)
        
        let systemMsg = ChatMessage(id: UUID(), role: .system, content: "")
        messages.append(systemMsg)
        
        let question = userMessage
        userMessage = ""
        isSending = true
        currentStreamingID = systemMsg.id
        streamingContent = ""
        
        Task {
            do {
                let prompt = """
                你是一个专业的学习助手。请用中文回答用户的问题。如果需要，可以结合学习资料中的知识点进行解答。
                """
                
                try await appState.llmService.sendMessageStreaming(system: prompt, user: question) { chunk in
                    Task { @MainActor in
                        self.streamingContent += chunk
                        if let index = self.messages.firstIndex(where: { $0.id == self.currentStreamingID }) {
                            self.messages[index] = ChatMessage(id: self.currentStreamingID!, role: .system, content: self.streamingContent)
                        }
                    }
                }
                
                await MainActor.run {
                    isSending = false
                    currentStreamingID = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    isSending = false
                    currentStreamingID = nil
                }
            } catch {
                await MainActor.run {
                    if let index = messages.firstIndex(where: { $0.id == systemMsg.id }) {
                        messages[index] = ChatMessage(id: systemMsg.id, role: .system, content: "抱歉，发生错误: \(error.localizedDescription)")
                    }
                    isSending = false
                    currentStreamingID = nil
                }
            }
        }
    }
    
    private func cancelCurrentRequest() {
        appState.llmService.cancelCurrentRequest()
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var content: String
    
    enum MessageRole: String {
        case user
        case system
    }
}

struct ChatMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.role == .system {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
            } else {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.blue)
                    .frame(width: 30)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "你" : "AI 助手")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
            }
            
            Spacer()
        }
        .padding()
        .background(message.role == .user ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}
