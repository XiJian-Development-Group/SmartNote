import Foundation
import Combine
import Network

class P2PService: ObservableObject {
    static let shared = P2PService()

    @Published var currentIdentity: P2PUserIdentity?
    @Published var friends: [P2PFriend] = []
    @Published var groups: [P2PGroup] = []
    @Published var blackList: [P2PBlackIP] = []
    @Published var isBackgroundEnabled = false
    @Published var connectionStatus: [UUID: P2PFriend.FriendStatus] = [:]
    @Published var pendingConnections: [P2PPendingConnection] = []
    @Published var chatMessages: [UUID: [P2PChatMessage]] = [:]
    @Published var groupMessages: [UUID: [P2PGroupMessage]] = [:]

    private let cryptoService = P2PCryptoService.shared
    private let networkService = P2PNetworkService.shared
    private let storageService = StorageService()
    /// Maps a local connection ID → the peer's identity UUID (the stable friend identifier)
    private var connToFriendMap: [UUID: UUID] = [:]

    private init() {
        loadData()
        setupNetworkHandlers()
    }

    private func loadData() {
        currentIdentity = storageService.loadP2PIdentity()
        friends = storageService.loadP2PFriends()
        groups = storageService.loadP2PGroups()
        blackList = storageService.loadP2PBlackList()
        chatMessages = loadEncryptedMessages(from: storageService.p2pMessagesFileURL)
        groupMessages = loadEncryptedGroupMessages(from: storageService.p2pGroupMessagesFileURL)
        isBackgroundEnabled = storageService.loadSettings().p2pBackgroundEnabled

        if let identity = currentIdentity {
            networkService.startListening(port: UInt16(identity.port > 0 ? identity.port : 0))
        }
    }

    private func loadEncryptedMessages(from url: URL) -> [UUID: [P2PChatMessage]] {
        guard let encrypted = try? Data(contentsOf: url),
              let decrypted = cryptoService.decryptLocalData(encrypted),
              let messages = try? JSONDecoder().decode([UUID: [P2PChatMessage]].self, from: decrypted) else {
            return [:]
        }
        return messages
    }

    private func loadEncryptedGroupMessages(from url: URL) -> [UUID: [P2PGroupMessage]] {
        guard let encrypted = try? Data(contentsOf: url),
              let decrypted = cryptoService.decryptLocalData(encrypted),
              let messages = try? JSONDecoder().decode([UUID: [P2PGroupMessage]].self, from: decrypted) else {
            return [:]
        }
        return messages
    }

    private func setupNetworkHandlers() {
        networkService.onMessageReceived = { [weak self] connID, data in
            self?.handleReceivedData(connID, data: data)
        }
        networkService.onConnectionStatusChanged = { [weak self] connID, state in
            self?.handleConnectionStatusChanged(connID, state: state)
        }
        networkService.onIncomingConnection = { [weak self] ipv6, port in
            self?.handleIncomingConnection(ipv6: ipv6, port: port)
        }
    }

    /// Resolve the stable friend identity UUID for a given connection ID.
    private func friendID(for connID: UUID) -> UUID {
        connToFriendMap[connID] ?? connID
    }

    // MARK: - Identity

    func createIdentity(nickname: String, signature: String = "", avatarData: Data? = nil) -> Bool {
        guard let keyData = cryptoService.generateRSAKeyPair() else { return false }
        let identity = P2PUserIdentity(
            nickname: nickname,
            avatarData: avatarData,
            signature: signature,
            publicKey: keyData.publicKey,
            privateKeyRef: keyData.privateKeyRef,
            keyFingerprint: keyData.fingerprint,
            ipv6Address: networkService.localIPv6Address,
            port: networkService.localPort
        )
        currentIdentity = identity
        storageService.saveP2PIdentity(identity)
        networkService.startListening(port: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            var updated = identity
            updated.ipv6Address = self?.networkService.localIPv6Address ?? ""
            updated.port = self?.networkService.localPort ?? 0
            self?.currentIdentity = updated
            self?.storageService.saveP2PIdentity(updated)
        }
        return true
    }

    func updateIdentity(nickname: String? = nil, signature: String? = nil, avatarData: Data? = nil) {
        guard var identity = currentIdentity else { return }
        if let v = nickname { identity.nickname = v }
        if let v = signature { identity.signature = v }
        if let v = avatarData { identity.avatarData = v }
        identity.updatedAt = Date()
        currentIdentity = identity
        storageService.saveP2PIdentity(identity)
    }

    func resetIdentity() {
        if let identity = currentIdentity {
            cryptoService.deletePrivateKey(identifier: identity.privateKeyRef)
        }
        networkService.disconnectAll()
        networkService.stopListening()
        cryptoService.deleteLocalStorageKey()
        currentIdentity = nil
        friends = []; groups = []; blackList = []; pendingConnections = []
        chatMessages = [:]; groupMessages = [:]; connToFriendMap = [:]
        storageService.deleteP2PIdentity()
        storageService.deleteAllP2PFriends()
        storageService.deleteP2PBlackList()
        storageService.deleteAllP2PGroups()
        try? FileManager.default.removeItem(at: storageService.p2pMessagesFileURL)
        try? FileManager.default.removeItem(at: storageService.p2pGroupMessagesFileURL)
    }

    // MARK: - Connection

    /// Connect to a peer. `friendID` should be the existing `P2PFriend.id` if reconnecting, nil for new connections.
    func connectToFriend(ipv6Address: String, port: Int, friendID: UUID? = nil) -> UUID? {
        for ip in blackList {
            if ipv6Address.hasPrefix(ip.ipv6Address) { return nil }
        }
        let connID = friendID ?? UUID()
        guard networkService.connectToPeer(ipv6Address: ipv6Address, port: UInt16(port), friendID: connID) else {
            return nil
        }
        if let fid = friendID {
            connToFriendMap[connID] = fid
        }
        return connID
    }

    /// Reconnect to an existing friend using stored address info.
    func reconnectToFriend(_ friend: P2PFriend) -> Bool {
        guard !friend.ipv6Address.isEmpty, friend.port > 0 else { return false }
        return connectToFriend(ipv6Address: friend.ipv6Address, port: friend.port, friendID: friend.id) != nil
    }

    func acceptPendingConnection(_ pending: P2PPendingConnection) {
        let friend = P2PFriend(
            id: pending.id,
            nickname: pending.nickname,
            ipv6Address: pending.ipv6Address,
            port: pending.port,
            publicKey: pending.publicKey
        )
        friends.append(friend)
        storageService.saveP2PFriends(friends)
        pendingConnections.removeAll { $0.id == pending.id }
        connToFriendMap[pending.id] = pending.id
        connectionStatus[pending.id] = .online
        addSystemMessage(friendID: pending.id, content: "已连接")
    }

    func rejectPendingConnection(_ pending: P2PPendingConnection) {
        networkService.disconnect(friendID: pending.id)
        pendingConnections.removeAll { $0.id == pending.id }
    }

    // MARK: - Blacklist

    func addToBlackList(ipv6Address: String, reason: String = "") {
        let blackIP = P2PBlackIP(ipv6Address: ipv6Address, reason: reason)
        blackList.append(blackIP)
        storageService.saveP2PBlackList(blackList)
    }

    func removeFromBlackList(ipv6Address: String) {
        blackList.removeAll { $0.ipv6Address == ipv6Address }
        storageService.saveP2PBlackList(blackList)
    }

    // MARK: - Send Message

    func sendMessage(_ content: String, to friendID: UUID, type: P2PChatMessage.MessageType = .text) {
        let message = P2PChatMessage(friendID: friendID, content: content, isSent: true, status: .sending, type: type)

        // Find the connection for this friend via connToFriendMap
        let connID = connToFriendMap.first(where: { $0.value == friendID })?.key ?? friendID
        guard let connection = networkService.connections[connID],
              let aesKey = connection.aesKey,
              let messageData = content.data(using: .utf8),
              let encryptedData = cryptoService.aesEncrypt(messageData, key: aesKey) else {
            var msg = message; msg.status = .failed
            appendChatMessage(msg)
            return
        }

        var packet = Data([P2PPacketType.chatMessage.rawValue])
        packet.append(encryptedData)

        if networkService.send(packet, to: connID) {
            var msg = message; msg.status = .sent
            appendChatMessage(msg)
            updateFriendPreview(friendID: friendID, content: content)
        } else {
            var msg = message; msg.status = .failed
            appendChatMessage(msg)
        }
    }

    // MARK: - Group

    func createGroup(name: String, memberIDs: [UUID]) {
        let group = P2PGroup(name: name, memberIDs: memberIDs)
        groups.append(group)
        storageService.saveP2PGroups(groups)
    }

    func deleteGroup(_ group: P2PGroup) {
        groups.removeAll { $0.id == group.id }
        groupMessages.removeValue(forKey: group.id)
        storageService.saveP2PGroups(groups)
        saveGroupMessages()
    }

    func addMemberToGroup(groupID: UUID, friendID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }),
              !groups[idx].memberIDs.contains(friendID) else { return }
        groups[idx].memberIDs.append(friendID)
        storageService.saveP2PGroups(groups)
    }

    func removeMemberFromGroup(groupID: UUID, friendID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].memberIDs.removeAll { $0 == friendID }
        storageService.saveP2PGroups(groups)
    }

    func sendGroupMessage(_ content: String, to groupID: UUID) {
        guard let identity = currentIdentity else { return }
        let message = P2PGroupMessage(groupID: groupID, senderNickname: identity.nickname, content: content)
        appendGroupMessage(message)

        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for memberID in group.memberIDs {
            let connID = connToFriendMap.first(where: { $0.value == memberID })?.key ?? memberID
            guard let connection = networkService.connections[connID],
                  let aesKey = connection.aesKey,
                  let messageData = content.data(using: .utf8),
                  let encryptedData = cryptoService.aesEncrypt(messageData, key: aesKey) else {
                continue
            }
            var packet = Data([P2PPacketType.groupMessage.rawValue])
            packet.append(groupID.uuidString.data(using: .utf8)!)
            packet.append(encryptedData)
            networkService.send(packet, to: connID)
        }
    }

    // MARK: - Background

    func setBackgroundEnabled(_ enabled: Bool) {
        isBackgroundEnabled = enabled
        var settings = storageService.loadSettings()
        settings.p2pBackgroundEnabled = enabled
        storageService.saveSettings(settings)
        if !enabled { networkService.disconnectAll() }
    }

    // MARK: - Packet Handling

    private func handleReceivedData(_ connID: UUID, data: Data) {
        guard data.count > 1 else { return }
        switch data[0] {
        case P2PPacketType.handshake.rawValue:       handleHandshake(connID, data: data.dropFirst())
        case P2PPacketType.handshakeAck.rawValue:    handleHandshakeAck(connID, data: data.dropFirst())
        case P2PPacketType.chatMessage.rawValue:     handleChatMessage(connID, data: data.dropFirst())
        case P2PPacketType.groupMessage.rawValue:    handleGroupMessage(connID, data: data.dropFirst())
        case P2PPacketType.statusMessage.rawValue:   handleStatusMessage(connID, data: data.dropFirst())
        default: break
        }
    }

    // MARK: - Handshake

    /// Handshake payload: [identityUUID (36 bytes uuidString)] [nicknameLen (1)] [nickname] [pubKeyLen (2 BE)] [pubKey]
    private func handleHandshake(_ connID: UUID, data: Data.SubSequence) {
        let data = Data(data)
        guard data.count >= 37 else { return }

        var offset = 0
        let idStr = String(data: data[offset..<offset+36], encoding: .utf8) ?? ""
        offset += 36
        guard let peerIdentityID = UUID(uuidString: idStr) else { return }
        let nicknameLen = Int(data[offset]); offset += 1
        guard offset + nicknameLen <= data.count else { return }
        let nickname = String(data: data[offset..<offset+nicknameLen], encoding: .utf8) ?? "Unknown"
        offset += nicknameLen
        guard offset + 2 <= data.count else { return }
        let pubKeyLen = Int(UInt16(data[offset]) << 8 | UInt16(data[offset+1]))
        offset += 2
        guard offset + pubKeyLen <= data.count else { return }
        let publicKey = String(data: data[offset..<offset+pubKeyLen], encoding: .utf8) ?? ""

        print("[P2P] Handshake from \(nickname) (identity: \(peerIdentityID))")

        // Generate AES key and encrypt with peer's public key
        let aesKey = cryptoService.generateAESKey()
        guard let encryptedAESKey = cryptoService.encryptWithPublicKey(aesKey, publicKeyString: publicKey) else {
            print("[P2P] Failed to encrypt AES key for handshake"); return
        }

        // Set AES key on our connection
        if let connection = networkService.connections[connID] {
            connection.aesKey = aesKey
            connection.handshakeCompleted = true
        }

        // Map this connection to the peer's identity UUID
        connToFriendMap[connID] = peerIdentityID

        // Check if known friend
        if friends.contains(where: { $0.id == peerIdentityID }) {
            connectionStatus[peerIdentityID] = .online
            addSystemMessage(friendID: peerIdentityID, content: "\(nickname) 已上线")
        } else {
            // Show pending connection (use identity UUID as pending id)
            let pending = P2PPendingConnection(
                id: peerIdentityID,
                nickname: nickname,
                publicKey: publicKey,
                ipv6Address: "",
                port: 0
            )
            if !pendingConnections.contains(where: { $0.id == peerIdentityID }) {
                pendingConnections.append(pending)
            }
        }

        // Send handshake ack
        sendHandshakeAck(to: connID, encryptedAESKey: encryptedAESKey)
    }

    private func handleHandshakeAck(_ connID: UUID, data: Data.SubSequence) {
        let data = Data(data)
        guard data.count >= 37 + 256, let identity = currentIdentity else { return }

        var offset = 0
        let idStr = String(data: data[offset..<offset+36], encoding: .utf8) ?? ""
        offset += 36
        guard let peerIdentityID = UUID(uuidString: idStr) else { return }
        let nicknameLen = Int(data[offset]); offset += 1
        offset += nicknameLen
        guard offset + 2 <= data.count else { return }
        let pubKeyLen = Int(UInt16(data[offset]) << 8 | UInt16(data[offset+1]))
        offset += 2
        guard offset + pubKeyLen + 256 <= data.count else { return }
        offset += pubKeyLen
        let encryptedAESKey = data[offset..<offset+256]

        guard let aesKey = cryptoService.decryptWithPrivateKey(Data(encryptedAESKey), privateKeyRef: identity.privateKeyRef) else {
            print("[P2P] Failed to decrypt AES key from handshake ack"); return
        }

        if let connection = networkService.connections[connID] {
            connection.aesKey = aesKey
            connection.handshakeCompleted = true
        }

        connToFriendMap[connID] = peerIdentityID
        // If this peer is already a friend, update status
        if friends.contains(where: { $0.id == peerIdentityID }) {
            connectionStatus[peerIdentityID] = .online
            addSystemMessage(friendID: peerIdentityID, content: "已连接")
        }
        print("[P2P] Handshake completed for \(peerIdentityID)")
    }

    private func sendHandshake(to connID: UUID) {
        guard let identity = currentIdentity else { return }
        let nicknameData = identity.nickname.data(using: .utf8) ?? Data()
        let pubKeyData = identity.publicKey.data(using: .utf8) ?? Data()
        let uuidStr = identity.id.uuidString

        var packet = Data()
        packet.append(P2PPacketType.handshake.rawValue)
        packet.append(uuidStr.data(using: .utf8) ?? Data(count: 36))
        packet.append(UInt8(nicknameData.count))
        packet.append(nicknameData)
        packet.append(UInt16(pubKeyData.count).bigEndian.data)
        packet.append(pubKeyData)

        networkService.send(packet, to: connID)
        print("[P2P] Sent handshake on conn \(connID)")
    }

    private func sendHandshakeAck(to connID: UUID, encryptedAESKey: Data) {
        guard let identity = currentIdentity else { return }
        let nicknameData = identity.nickname.data(using: .utf8) ?? Data()
        let pubKeyData = identity.publicKey.data(using: .utf8) ?? Data()
        let uuidStr = identity.id.uuidString

        var packet = Data()
        packet.append(P2PPacketType.handshakeAck.rawValue)
        packet.append(uuidStr.data(using: .utf8) ?? Data(count: 36))
        packet.append(UInt8(nicknameData.count))
        packet.append(nicknameData)
        packet.append(UInt16(pubKeyData.count).bigEndian.data)
        packet.append(pubKeyData)
        packet.append(encryptedAESKey)

        networkService.send(packet, to: connID)
        print("[P2P] Sent handshake ack on conn \(connID)")
    }

    // MARK: - Message Handlers

    private func handleChatMessage(_ connID: UUID, data: Data.SubSequence) {
        guard let connection = networkService.connections[connID],
              let aesKey = connection.aesKey,
              let decryptedData = cryptoService.aesDecrypt(Data(data), key: aesKey),
              let content = String(data: decryptedData, encoding: .utf8) else { return }

        let fid = friendID(for: connID)
        let message = P2PChatMessage(friendID: fid, content: content, isSent: false, status: .delivered)
        appendChatMessage(message)
        updateFriendPreview(friendID: fid, content: content)
        updateFriendTimestamp(friendID: fid)
    }

    private func handleGroupMessage(_ connID: UUID, data: Data.SubSequence) {
        guard let connection = networkService.connections[connID],
              let aesKey = connection.aesKey else { return }
        let data = Data(data)
        guard data.count > 36 else { return }
        let groupIDString = String(data: data.prefix(36), encoding: .utf8) ?? ""
        guard let groupID = UUID(uuidString: groupIDString) else { return }
        let encryptedData = data.dropFirst(36)
        guard let decryptedData = cryptoService.aesDecrypt(Data(encryptedData), key: aesKey),
              let content = String(data: decryptedData, encoding: .utf8) else { return }

        let fid = friendID(for: connID)
        let senderNickname = friends.first(where: { $0.id == fid })?.nickname ?? "Unknown"
        let message = P2PGroupMessage(groupID: groupID, senderNickname: senderNickname, content: content)
        appendGroupMessage(message)
    }

    private func handleStatusMessage(_ connID: UUID, data: Data.SubSequence) {
        guard let connection = networkService.connections[connID],
              let aesKey = connection.aesKey,
              let decryptedData = cryptoService.aesDecrypt(Data(data), key: aesKey),
              let statusString = String(data: decryptedData, encoding: .utf8) else { return }
        let fid = friendID(for: connID)
        connectionStatus[fid] = P2PFriend.FriendStatus(rawValue: statusString)
    }

    // MARK: - Connection Status

    private func handleConnectionStatusChanged(_ connID: UUID, state: NWConnection.State) {
        switch state {
        case .ready:
            if let connection = networkService.connections[connID], connection.isOutgoing {
                sendHandshake(to: connID)
            }
            // For incoming connections, status is set during handshake
        case .failed, .cancelled:
            let fid = friendID(for: connID)
            connectionStatus[fid] = .offline
            pendingConnections.removeAll { $0.id == fid || $0.id == connID }
            if let friend = friends.first(where: { $0.id == fid }) {
                addSystemMessage(friendID: fid, content: "\(friend.nickname) 已离线")
            }
            connToFriendMap.removeValue(forKey: connID)
        default:
            break
        }
    }

    private func handleIncomingConnection(ipv6: String, port: Int) {
        for ip in blackList {
            if ipv6.hasPrefix(ip.ipv6Address) { return }
        }
        print("[P2P] Incoming connection from \(ipv6):\(port)")
    }

    // MARK: - Message Persistence

    private func appendChatMessage(_ message: P2PChatMessage) {
        if chatMessages[message.friendID] == nil { chatMessages[message.friendID] = [] }
        chatMessages[message.friendID]?.append(message)
        saveChatMessages()
    }

    private func appendGroupMessage(_ message: P2PGroupMessage) {
        if groupMessages[message.groupID] == nil { groupMessages[message.groupID] = [] }
        groupMessages[message.groupID]?.append(message)
        saveGroupMessages()
    }

    private func addSystemMessage(friendID: UUID, content: String) {
        let msg = P2PChatMessage(friendID: friendID, content: content, isSent: true, status: .delivered, type: .system)
        appendChatMessage(msg)
    }

    private func updateFriendPreview(friendID: UUID, content: String) {
        if let idx = friends.firstIndex(where: { $0.id == friendID }) {
            friends[idx].lastMessagePreview = String(content.prefix(80))
            friends[idx].lastMessageAt = Date()
            storageService.saveP2PFriends(friends)
        }
    }

    private func updateFriendTimestamp(friendID: UUID) {
        if let idx = friends.firstIndex(where: { $0.id == friendID }) {
            friends[idx].lastMessageAt = Date()
            storageService.saveP2PFriends(friends)
        }
    }

    private func saveChatMessages() {
        guard let data = try? JSONEncoder().encode(chatMessages),
              let encrypted = cryptoService.encryptLocalData(data) else { return }
        try? encrypted.write(to: storageService.p2pMessagesFileURL, options: .atomic)
    }

    private func saveGroupMessages() {
        guard let data = try? JSONEncoder().encode(groupMessages),
              let encrypted = cryptoService.encryptLocalData(data) else { return }
        try? encrypted.write(to: storageService.p2pGroupMessagesFileURL, options: .atomic)
    }

    // MARK: - Helpers

    func getIPv6Address() -> String { networkService.localIPv6Address }
    func getPort() -> Int { networkService.localPort }
    func nicknameForFriend(_ id: UUID) -> String {
        friends.first(where: { $0.id == id })?.nickname ?? "Unknown"
    }
}

extension UInt16 {
    var data: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}
