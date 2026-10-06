import SwiftUI

struct AIChatView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @State private var messageText = ""
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = false

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp = Date()

        enum Role { case user, assistant }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("AI 正在思考...")
                                        .font(.caption)
                                        .foregroundStyle(appTheme.secondaryText)
                                }
                                .padding()
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // 输入区域
                HStack(spacing: 8) {
                    TextField("输入消息...", text: $messageText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .disabled(isLoading)

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                }
                .padding()
                .background(appTheme.background)
            }
            .navigationTitle("AI 对话")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("清空对话") { messages.removeAll() }
                        Button("导出对话") { /* 导出 */ }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private func sendMessage() {
        let userMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }

        let userChatMessage = ChatMessage(role: .user, content: userMessage)
        messages.append(userChatMessage)
        messageText = ""
        isLoading = true

        Task {
            do {
                let response = try await appState.llmService.chat(messages: messages.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.content] })
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: response))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: "抱歉，发生错误：\(error.localizedDescription)"))
                    isLoading = false
                }
            }
        }
    }
}

struct MessageBubble: View {
    @Environment(\.appTheme) private var appTheme
    let message: AIChatView_iOS.ChatMessage

    var body: some View {
        HStack {
            if message.role == .assistant { Spacer(minLength: 40) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == .user
                        ? appTheme.accent
                        : appTheme.surface
                    )
                    .foregroundStyle(
                        message.role == .user
                        ? .white
                        : appTheme.primaryText
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
                    .padding(.horizontal, 4)
            }

            if message.role == .user { Spacer(minLength: 40) }
        }
    }
}