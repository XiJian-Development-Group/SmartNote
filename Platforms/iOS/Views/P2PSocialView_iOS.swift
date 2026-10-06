import SwiftUI

/// iOS 局域网社交界面。
///
/// 身份、好友与群组数据由 Shared 的 `P2PService` 提供（端到端加密的
/// 局域网直连），本视图负责身份创建/管理、好友列表、群组与聊天入口。
struct P2PSocialView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var service = P2PService.shared
    @State private var showsIdentityEditor = false
    @State private var showsAddFriend = false
    @State private var showsCreateGroup = false
    @State private var selectedChatFriend: P2PFriend?
    @State private var selectedChatGroup: P2PGroup?

    var body: some View {
        List {
            identitySection
            pendingSection
            friendsSection
            groupsSection
            securitySection
        }
        .navigationTitle("局域网社交")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsIdentityEditor = true
                    } label: {
                        Label(
                            service.currentIdentity == nil ? "创建身份" : "编辑身份",
                            systemImage: "person.badge.key"
                        )
                    }
                    Button {
                        showsAddFriend = true
                    } label: {
                        Label("添加好友", systemImage: "person.badge.plus")
                    }
                    .disabled(service.currentIdentity == nil)
                    Button {
                        showsCreateGroup = true
                    } label: {
                        Label("创建群组", systemImage: "person.3")
                    }
                    .disabled(service.friends.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showsIdentityEditor) {
            P2PIdentityEditor_iOS { nickname, signature in
                _ = service.createIdentity(nickname: nickname, signature: signature)
            }
        }
        .sheet(isPresented: $showsAddFriend) {
            P2PAddFriend_iOS { address, port, friendID in
                _ = service.connectToFriend(ipv6Address: address, port: port, friendID: friendID)
            }
        }
        .sheet(isPresented: $showsCreateGroup) {
            P2PCreateGroup_iOS(availableFriends: service.friends) { name, memberIDs in
                service.createGroup(name: name, memberIDs: memberIDs)
            }
        }
        .sheet(item: $selectedChatFriend) { friend in
            P2PChatView_iOS(friend: friend, service: service)
        }
        .sheet(item: $selectedChatGroup) { group in
            P2PGroupChatView_iOS(group: group, service: service)
        }
        .alert("安全提醒", isPresented: Binding(
            get: { service.securityAlert != nil },
            set: { if !$0 { service.dismissSecurityAlert() } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(service.securityAlert?.message ?? "")
        }
    }

    // MARK: - 身份

    private var identitySection: some View {
        Section("我的身份") {
            if let identity = service.currentIdentity {
                VStack(alignment: .leading, spacing: 6) {
                    Text(identity.nickname)
                        .font(.headline)
                        .foregroundStyle(appTheme.primaryText)
                    if !identity.signature.isEmpty {
                        Text(identity.signature)
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }
                    Text("指纹：\(service.fingerprint(forPublicKey: identity.publicKey))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(appTheme.secondaryText)
                }
            } else {
                Button {
                    showsIdentityEditor = true
                } label: {
                    Label("创建身份", systemImage: "person.badge.key")
                }
            }
        }
    }

    // MARK: - 待处理连接

    @ViewBuilder
    private var pendingSection: some View {
        if !service.pendingConnections.isEmpty {
            Section("待处理连接（\(service.pendingConnections.count)）") {
                ForEach(service.pendingConnections) { pending in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(pending.nickname.isEmpty ? pending.ipv6Address : pending.nickname)
                            .font(.subheadline)
                        HStack(spacing: 12) {
                            Button("接受") { service.acceptPendingConnection(pending) }
                                .buttonStyle(.borderedProminent)
                            Button("拒绝") { service.rejectPendingConnection(pending) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 好友

    @ViewBuilder
    private var friendsSection: some View {
        Section("好友（\(service.friends.count)）") {
            if service.friends.isEmpty {
                Text("还没有好友。创建身份后，把你的 IPv6 地址告诉同一局域网内的朋友。")
                    .font(.footnote)
                    .foregroundStyle(appTheme.secondaryText)
            } else {
                ForEach(service.friends) { friend in
                    Button {
                        selectedChatFriend = friend
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(friend.nickname)
                                    .foregroundStyle(appTheme.primaryText)
                                Text(connectionText(for: friend))
                                    .font(.caption)
                                    .foregroundStyle(appTheme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(appTheme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 群组

    @ViewBuilder
    private var groupsSection: some View {
        if !service.groups.isEmpty {
            Section("群组（\(service.groups.count)）") {
                ForEach(service.groups) { group in
                    Button {
                        selectedChatGroup = group
                    } label: {
                        HStack {
                            Label(group.name, systemImage: "person.3")
                                .foregroundStyle(appTheme.primaryText)
                            Spacer()
                            Text("\(group.memberIDs.count) 人")
                                .font(.caption)
                                .foregroundStyle(appTheme.secondaryText)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 安全

    @ViewBuilder
    private var securitySection: some View {
        if !service.blackList.isEmpty {
            Section("黑名单（\(service.blackList.count)）") {
                ForEach(service.blackList) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.ipv6Address).font(.caption.monospaced())
                            if !entry.reason.isEmpty {
                                Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("移除") { service.removeFromBlackList(ipv6Address: entry.ipv6Address) }
                            .font(.caption)
                    }
                }
            }
        }
    }

    /// 运行期连接状态优先；没有活跃连接时回退到好友自身记录的状态。
    private func connectionText(for friend: P2PFriend) -> String {
        switch service.connectionStatus[friend.id] ?? friend.status {
        case .online: return "在线"
        case .offline: return "离线"
        case .focusing: return "专注中"
        }
    }
}

// MARK: - 身份编辑

private struct P2PIdentityEditor_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let onCommit: (String, String) -> Void

    @State private var nickname = ""
    @State private var signature = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("身份") {
                    TextField("昵称", text: $nickname)
                    TextField("个性签名", text: $signature, axis: .vertical).lineLimit(1...3)
                }
                Section {
                    Text("身份密钥会保存在本机钥匙串中，不会离开这台设备。")
                        .font(.footnote)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }
            .navigationTitle("创建身份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCommit(
                            nickname.trimmingCharacters(in: .whitespaces),
                            signature.trimmingCharacters(in: .whitespaces)
                        )
                        dismiss()
                    }
                    .disabled(nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 添加好友

private struct P2PAddFriend_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let onConnect: (String, Int, UUID?) -> Void

    @State private var address = ""
    @State private var portText = ""
    @State private var friendID = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("连接信息") {
                    TextField("IPv6 地址", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口（留空则使用默认端口）", text: $portText)
                        .keyboardType(.numberPad)
                    TextField("好友 ID（可选）", text: $friendID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("两台设备必须处于同一局域网，且都开启「允许被连接」。")
                        .font(.footnote)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        // 留空时传 0，由 `P2PNetworkService.startListening(port:)`
                        // 约定的方式选择端口；连接方需要与监听方一致。
                        let parsedPort = Int(portText) ?? 0
                        let parsedID = UUID(uuidString: friendID)
                        onConnect(
                            address.trimmingCharacters(in: .whitespaces),
                            parsedPort,
                            parsedID
                        )
                        dismiss()
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - 创建群组

private struct P2PCreateGroup_iOS: View {
    @Environment(\.dismiss) private var dismiss

    let availableFriends: [P2PFriend]
    let onCreate: (String, [UUID]) -> Void

    @State private var name = ""
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                Section("群组名称") {
                    TextField("名称", text: $name)
                }
                Section("成员") {
                    ForEach(availableFriends) { friend in
                        Button {
                            if selected.contains(friend.id) {
                                selected.remove(friend.id)
                            } else {
                                selected.insert(friend.id)
                            }
                        } label: {
                            HStack {
                                Text(friend.nickname)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(friend.id) ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("创建群组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        onCreate(name.trimmingCharacters(in: .whitespaces), Array(selected))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - 好友聊天

private struct P2PChatView_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let friend: P2PFriend
    @ObservedObject var service: P2PService

    @State private var draft = ""

    private var messages: [P2PChatMessage] {
        service.chatMessages[friend.id] ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !service.canSendToFriend(friend.id) {
                    Text("对方尚未信任你的密钥，消息不会发送。可在对方确认后重试。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { message in
                                MessageBubble_iOS(
                                    text: message.content,
                                    isOutgoing: message.isSent,
                                    date: message.timestamp
                                )
                                .id(message.id)
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

                HStack(spacing: 10) {
                    TextField("输入消息", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(appTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Button {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        service.sendMessage(text, to: friend.id)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(appTheme.surfaceElevated)
            }
            .navigationTitle(friend.nickname)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

// MARK: - 群组聊天

private struct P2PGroupChatView_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let group: P2PGroup
    @ObservedObject var service: P2PService

    @State private var draft = ""

    private var messages: [P2PGroupMessage] {
        service.groupMessages[group.id] ?? []
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(messages) { message in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(message.senderNickname)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(appTheme.accent)
                                    MessageBubble_iOS(
                                        text: message.content,
                                        // 群消息模型不带方向字段，用发送者是否为本机判断。
                                        isOutgoing: message.senderNickname == service.currentIdentity?.nickname,
                                        date: message.timestamp
                                    )
                                }
                                .id(message.id)
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

                HStack(spacing: 10) {
                    TextField("输入消息", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(appTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Button {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        service.sendGroupMessage(text, to: group.id)
                        draft = ""
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(appTheme.surfaceElevated)
            }
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

// MARK: - 消息气泡

private struct MessageBubble_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let text: String
    let isOutgoing: Bool
    let date: Date

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 40) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(appTheme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isOutgoing ? appTheme.accent.opacity(0.2) : appTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
            }

            if !isOutgoing { Spacer(minLength: 40) }
        }
    }
}