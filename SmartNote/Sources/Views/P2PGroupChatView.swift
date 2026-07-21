import SwiftUI

struct P2PGroupChatView: View {
    @Environment(\.dismiss) private var dismiss
    let group: P2PGroup
    @StateObject private var p2pService = P2PService.shared
    @State private var messageText = ""
    @State private var messages: [P2PGroupMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { message in
                            GroupMessageBubble(
                                message: message,
                                isOwn: message.senderNickname == p2pService.currentIdentity?.nickname
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            Divider()
            inputBar
        }
        .onAppear(perform: loadMessages)
        .onReceive(p2pService.$groupMessages) { _ in
            loadMessages()
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.3.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.headline)
                let onlineCount = group.memberIDs.filter { p2pService.connectionStatus[$0] == .online }.count
                Text("\(group.memberIDs.count) 人 · \(onlineCount) 在线")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("输入群消息...", text: $messageText)
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
        messages = p2pService.groupMessages[group.id] ?? []
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        p2pService.sendGroupMessage(messageText, to: group.id)
        messageText = ""
    }
}

struct GroupMessageBubble: View {
    let message: P2PGroupMessage
    let isOwn: Bool

    var body: some View {
        HStack {
            if isOwn { Spacer() }

            VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
                Text(message.senderNickname)
                    .font(.caption)
                    .foregroundColor(.accentColor)

                Text(message.content)
                    .padding(10)
                    .background(isOwn ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .cornerRadius(12)

                Text(formatTime(message.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !isOwn { Spacer() }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
