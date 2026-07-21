import SwiftUI

struct P2PSocialView: View {
    @StateObject private var p2pService = P2PService.shared
    @State private var selectedFriend: P2PFriend?
    @State private var selectedGroup: P2PGroup?
    @State private var showAddFriend = false
    @State private var showSettings = false
    @State private var showCreateGroup = false

    var body: some View {
        VStack(spacing: 0) {
            if let identity = p2pService.currentIdentity {
                identityHeader(identity)
                Divider()
                contentTabs
            } else {
                noIdentityView
            }
        }
        .sheet(isPresented: $showAddFriend) { P2PAddFriendView() }
        .sheet(isPresented: $showSettings) { P2PSettingsView() }
        .sheet(isPresented: $showCreateGroup) { P2PCreateGroupView() }
    }

    private func identityHeader(_ identity: P2PUserIdentity) -> some View {
        HStack {
            if let avatarData = identity.avatarData,
               let nsImage = NSImage(data: avatarData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 50, height: 50)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 50, height: 50)
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(identity.nickname)
                    .font(.headline)
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("在线")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Button { showCreateGroup = true } label: {
                        Image(systemName: "person.3")
                    }
                    .buttonStyle(.bordered)
                    .help("创建群组")

                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.bordered)

                    Button { showAddFriend = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @State private var selectedTab = 0

    private var contentTabs: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("好友").tag(0)
                Text("群组").tag(1)
                if !p2pService.pendingConnections.isEmpty {
                    Text("待处理 (\(p2pService.pendingConnections.count))").tag(2)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case 0: friendsView
            case 1: groupsView
            case 2: pendingView
            default: friendsView
            }
        }
    }

    private var friendsView: some View {
        Group {
            if p2pService.friends.isEmpty {
                emptyPlaceholder(
                    icon: "person.2.slash",
                    title: "暂无好友",
                    subtitle: "点击右上角 + 添加好友"
                )
            } else {
                List(p2pService.friends) { friend in
                    P2PFriendRow(friend: friend, status: p2pService.connectionStatus[friend.id])
                        .contentShape(Rectangle())
                        .onTapGesture { selectedFriend = friend }
                }
                .sheet(item: $selectedFriend) { friend in
                    P2PChatView(friend: friend)
                }
            }
        }
    }

    private var groupsView: some View {
        Group {
            if p2pService.groups.isEmpty {
                emptyPlaceholder(
                    icon: "person.3.slash",
                    title: "暂无群组",
                    subtitle: "点击右上角创建群组"
                )
            } else {
                List(p2pService.groups) { group in
                    P2PGroupRow(group: group, p2pService: p2pService)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedGroup = group }
                }
                .sheet(item: $selectedGroup) { group in
                    P2PGroupChatView(group: group)
                }
            }
        }
    }

    private var pendingView: some View {
        List(p2pService.pendingConnections) { pending in
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.nickname)
                        .font(.headline)
                    Text("请求连接")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    p2pService.rejectPendingConnection(pending)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.bordered)

                Button {
                    p2pService.acceptPendingConnection(pending)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    private func emptyPlaceholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var noIdentityView: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)
            Text("创建 P2P 社交身份")
                .font(.title2)
                .fontWeight(.bold)
            Text("创建后可与好友进行端到端加密聊天")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            P2PCreateIdentityView()
            Spacer()
        }
        .padding()
    }
}

struct P2PFriendRow: View {
    let friend: P2PFriend
    let status: P2PFriend.FriendStatus?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let avatarData = friend.avatarData,
                   let nsImage = NSImage(data: avatarData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 44, height: 44)
                        .foregroundColor(.accentColor)
                }

                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(friend.nickname)
                    .font(.headline)
                if let preview = friend.lastMessagePreview {
                    Text(preview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let lastMessageAt = friend.lastMessageAt {
                Text(formatTime(lastMessageAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch status {
        case .online: return .green
        case .focusing: return .orange
        case .offline, .none: return .gray
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct P2PGroupRow: View {
    let group: P2PGroup
    @ObservedObject var p2pService: P2PService

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.3.fill")
                .resizable()
                .frame(width: 44, height: 30)
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
        }
        .padding(.vertical, 4)
    }
}
