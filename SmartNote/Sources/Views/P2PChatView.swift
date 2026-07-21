import SwiftUI

struct P2PChatView: View {
    @Environment(\.dismiss) private var dismiss
    let friend: P2PFriend
    @StateObject private var p2pService = P2PService.shared
    @State private var messageText = ""
    @State private var messages: [P2PChatMessage] = []
    @State private var isConnected = false

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
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
            messageInput
        }
        .onAppear {
            loadMessages()
            if !isConnected {
                _ = p2pService.reconnectToFriend(friend)
            }
        }
        .onReceive(p2pService.$chatMessages) { _ in
            loadMessages()
        }
        .onReceive(p2pService.$connectionStatus) { _ in
            isConnected = p2pService.connectionStatus[friend.id] == .online
        }
    }

    private var chatHeader: some View {
        HStack {
            if let avatarData = friend.avatarData,
               let nsImage = NSImage(data: avatarData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading) {
                Text(friend.nickname)
                    .font(.headline)
                HStack(spacing: 4) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(isConnected ? "在线" : "离线")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    private var messageInput: some View {
        HStack(spacing: 12) {
            TextField("输入消息...", text: $messageText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(messageText.isEmpty)
        }
        .padding()
    }

    private func loadMessages() {
        messages = p2pService.chatMessages[friend.id] ?? []
        isConnected = p2pService.connectionStatus[friend.id] == .online
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        p2pService.sendMessage(messageText, to: friend.id)
        messageText = ""
    }
}

struct MessageBubble: View {
    let message: P2PChatMessage

    var body: some View {
        HStack {
            if message.isSent {
                Spacer()
            }

            VStack(alignment: message.isSent ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .padding(10)
                    .background(message.type == .system
                        ? Color.clear
                        : message.isSent ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    .font(message.type == .system ? .caption : .body)
                    .foregroundColor(message.type == .system ? .secondary : .primary)

                if message.type != .system {
                    HStack(spacing: 4) {
                        Text(formatTime(message.timestamp))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if message.isSent {
                            Image(systemName: statusIcon)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            if !message.isSent {
                Spacer()
            }
        }
    }

    private var statusIcon: String {
        switch message.status {
        case .sending: return "clock"
        case .sent: return "checkmark"
        case .delivered: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
