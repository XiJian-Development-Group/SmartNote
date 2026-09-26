import Foundation
import Combine
import Network

/// A user-visible security event. Keeping this separate from chat messages makes
/// it impossible for a failed authentication decision to look like plaintext.
///
/// The authenticated encryption protects message contents and detects tampering;
/// it does not by itself prevent replay, protocol downgrade, or a MITM that the
/// user has not verified through the out-of-band fingerprint flow.
struct P2PSecurityAlert: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String

    init(id: UUID = UUID(), title: String, message: String) {
        self.id = id
        self.title = title
        self.message = message
    }
}

struct P2PHandshakeInfo {
    let identityID: UUID
    let nickname: String
    let publicKey: String
    /// New peers append this capability byte. Nil means a legacy peer whose
    /// handshake had no capability field; its messages may still be CBC.
    let capabilityVersion: UInt8?

    init(identityID: UUID, nickname: String, publicKey: String, capabilityVersion: UInt8? = nil) {
        self.identityID = identityID
        self.nickname = nickname
        self.publicKey = publicKey
        self.capabilityVersion = capabilityVersion
    }
}

struct P2PHandshakeAckInfo {
    let identity: P2PHandshakeInfo
    let encryptedKey: Data
    let keyVersion: UInt8?
}

enum P2PProtocolError: Error, Equatable, LocalizedError {
    case emptyPacket
    case unknownPacketType(UInt8)
    case malformedHandshake
    case malformedPayload
    case invalidUTF8
    case invalidPublicKeyLength
    case invalidEncryptedKeyLength

    var errorDescription: String? {
        switch self {
        case .emptyPacket:
            return "数据包为空"
        case .unknownPacketType(let type):
            return "未知数据包类型：\(type)"
        case .malformedHandshake:
            return "握手字段长度无效"
        case .malformedPayload:
            return "数据包负载长度无效"
        case .invalidUTF8:
            return "握手文本不是有效 UTF-8"
        case .invalidPublicKeyLength:
            return "握手公钥长度无效"
        case .invalidEncryptedKeyLength:
            return "握手加密密钥长度无效"
        }
    }
}

/// Pure wire-format validation for packet frames. The socket layer validates
/// framing; this layer validates the packet type and every field before any
/// slice is accessed. No malformed input can turn into an out-of-bounds access.
enum P2PProtocolCodec {
    static let currentCapabilityVersion: UInt8 = 1
    static let uuidByteCount = 36
    static let maxPublicKeyByteCount = 32 * 1024
    static let rsa2048CiphertextByteCount = 256

    static func validatePacket(_ packet: Data) -> Result<(P2PPacketType, Data), P2PProtocolError> {
        guard let firstByte = packet.first else { return .failure(.emptyPacket) }
        guard let type = P2PPacketType(rawValue: firstByte) else {
            return .failure(.unknownPacketType(firstByte))
        }

        let payload = Data(packet.dropFirst())
        switch type {
        case .handshake:
            switch parseHandshakePayload(payload) {
            case .success:
                break
            case .failure(let error):
                return .failure(error)
            }
        case .handshakeAck:
            switch parseHandshakeAckPayload(payload) {
            case .success:
                break
            case .failure(let error):
                return .failure(error)
            }
        case .chatMessage, .statusMessage:
            guard !payload.isEmpty else { return .failure(.malformedPayload) }
        case .groupMessage:
            // group id is a canonical UUID string followed by an encrypted
            // payload; the latter is checked by the crypto layer.
            guard payload.count > P2PProtocolCodec.uuidByteCount else {
                return .failure(.malformedPayload)
            }
        }
        return .success((type, payload))
    }

    static func parseHandshakePayload(_ data: Data) -> Result<P2PHandshakeInfo, P2PProtocolError> {
        guard let parsed = parseIdentityPrefix(data) else {
            return .failure(.malformedHandshake)
        }
        let trailingCount = data.count - parsed.nextOffset
        guard trailingCount <= 1 else {
            return .failure(.malformedHandshake)
        }
        let capabilityVersion: UInt8?
        if trailingCount == 1 {
            let version = data[parsed.nextOffset]
            guard version == 1 else { return .failure(.malformedHandshake) }
            capabilityVersion = version
        } else {
            capabilityVersion = nil
        }
        return .success(P2PHandshakeInfo(
            identityID: parsed.info.identityID,
            nickname: parsed.info.nickname,
            publicKey: parsed.info.publicKey,
            capabilityVersion: capabilityVersion
        ))
    }

    static func parseHandshakeAckPayload(_ data: Data) -> Result<P2PHandshakeAckInfo, P2PProtocolError> {
        guard let parsed = parseIdentityPrefix(data) else {
            return .failure(.malformedHandshake)
        }

        let remaining = data.count - parsed.nextOffset
        // A legacy ack contains exactly the RSA-2048 ciphertext. New acks add
        // one explicit key-material version byte. Unknown lengths are rejected
        // rather than treated as a different protocol.
        guard remaining == rsa2048CiphertextByteCount || remaining == rsa2048CiphertextByteCount + 1 else {
            return .failure(.invalidEncryptedKeyLength)
        }

        let keyStart = parsed.nextOffset
        let keyEnd = keyStart + rsa2048CiphertextByteCount
        let encryptedKey = Data(data[keyStart..<keyEnd])
        let keyVersion = remaining == rsa2048CiphertextByteCount + 1 ? data[keyEnd] : nil
        return .success(P2PHandshakeAckInfo(
            identity: parsed.info,
            encryptedKey: encryptedKey,
            keyVersion: keyVersion
        ))
    }

    private static func parseIdentityPrefix(_ data: Data) -> (info: P2PHandshakeInfo, nextOffset: Int)? {
        guard data.count >= uuidByteCount + 1 else { return nil }

        let uuidData = Data(data[0..<uuidByteCount])
        guard let uuidString = String(data: uuidData, encoding: .utf8),
              let identityID = UUID(uuidString: uuidString) else {
            return nil
        }

        let nicknameLengthOffset = uuidByteCount
        let nicknameLength = Int(data[nicknameLengthOffset])
        guard nicknameLength > 0 else { return nil }

        let nicknameStart = nicknameLengthOffset + 1
        guard nicknameLength <= data.count - nicknameStart else { return nil }
        let nicknameEnd = nicknameStart + nicknameLength
        guard let nickname = String(data: data[nicknameStart..<nicknameEnd], encoding: .utf8),
              !nickname.isEmpty else {
            return nil
        }

        guard data.count >= nicknameEnd + 2 else { return nil }
        let publicKeyLength = (Int(data[nicknameEnd]) << 8) | Int(data[nicknameEnd + 1])
        guard publicKeyLength > 0,
              publicKeyLength <= maxPublicKeyByteCount else {
            return nil
        }

        let publicKeyStart = nicknameEnd + 2
        guard publicKeyLength <= data.count - publicKeyStart else { return nil }
        let publicKeyEnd = publicKeyStart + publicKeyLength
        guard let publicKey = String(data: data[publicKeyStart..<publicKeyEnd], encoding: .utf8),
              !publicKey.isEmpty else {
            return nil
        }

        return (
            P2PHandshakeInfo(identityID: identityID, nickname: nickname, publicKey: publicKey),
            publicKeyEnd
        )
    }
}

final class P2PService: ObservableObject {
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
    @Published var securityAlert: P2PSecurityAlert?
    @Published private(set) var trustedPeerIDs: Set<UUID> = []
    @Published private(set) var blockedPeerIDs: Set<UUID> = []

    private let cryptoService = P2PCryptoService.shared
    private let networkService = P2PNetworkService.shared
    private let storageService = StorageService()
    /// Maps a local connection ID → the peer's identity UUID (the stable friend identifier).
    private var connToFriendMap: [UUID: UUID] = [:]
    /// Maps a pending peer UUID → the local connection waiting for confirmation.
    private var pendingConnectionMap: [UUID: UUID] = [:]
    /// Message IDs that arrived through the unauthenticated legacy CBC format.
    /// They can be explicitly re-sent with the current GCM format if requested.
    private var legacyMessageIDs: Set<UUID> = []
    /// 聊天历史读取失败后禁止写回，避免用新密钥生成空历史覆盖旧密文。
    private var chatHistoryLoadFailed = false
    private var groupHistoryLoadFailed = false

    private init() {
        loadData()
        setupNetworkHandlers()
        // 「清除所有数据」后必须重置内存态。
        // 此前 P2PService 不监听该通知：磁盘文件被删光，但内存里还留着
        // 身份、好友和聊天记录；任何一次后续保存都会把文件重新写回来，
        // 相当于「清除」没有真正生效。
        clearAllDataObserver = NotificationCenter.default.addObserver(
            forName: .storageDidClearAllData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetAllLocalData() }
        }
    }

    private var clearAllDataObserver: NSObjectProtocol?

    /// 清空内存态并与磁盘保持一致。
    /// 监听器的启停由 loadData 末尾统一处理（身份为空时不会拉起后台监听）。
    private func resetAllLocalData() {
        currentIdentity = nil
        friends = []
        groups = []
        blackList = []
        chatMessages = [:]
        groupMessages = [:]
        connectionStatus = [:]
        chatHistoryLoadFailed = false
        groupHistoryLoadFailed = false
        // 重新从磁盘读一遍：此时应全部为空；若读出内容说明还有文件未纳入受管清单。
        loadData()
    }

    private func loadData() {
        currentIdentity = storageService.loadP2PIdentity()
        friends = storageService.loadP2PFriends()
        groups = storageService.loadP2PGroups()
        blackList = storageService.loadP2PBlackList()
        chatMessages = loadEncryptedMessages(from: storageService.p2pMessagesFileURL)
        groupMessages = loadEncryptedGroupMessages(from: storageService.p2pGroupMessagesFileURL)
        let settings = storageService.loadSettings()
        isBackgroundEnabled = settings.p2pBackgroundEnabled

        // Migrate the old short display value to the full SHA-256 fingerprint
        // when possible. Trust is still persisted by the existing publicKey
        // field in p2pFriends.json, so old friend records remain decodable.
        if var identity = currentIdentity,
           let publicKey = Data(base64Encoded: identity.publicKey),
           let canonicalFingerprint = canonicalFingerprint(for: publicKey),
           identity.keyFingerprint != canonicalFingerprint {
            identity.keyFingerprint = canonicalFingerprint
            currentIdentity = identity
            storageService.saveP2PIdentity(identity)
        }

        if isBackgroundEnabled, currentIdentity != nil {
            _ = networkService.startListening(
                port: UInt16(currentIdentity?.port ?? 0)
            )
        } else {
            // The switch owns the listener lifecycle. In particular, loading
            // with background mode off must not resurrect a stale listener.
            networkService.stopListening()
        }
    }

    private func loadEncryptedMessages(from url: URL) -> [UUID: [P2PChatMessage]] {
        // 没有文件是新安装，不当作损坏；只有存在但无法读取/解密/解码才隔离并锁定写回。
        guard FileManager.default.fileExists(atPath: url.path) else {
            chatHistoryLoadFailed = false
            return [:]
        }

        do {
            let encrypted = try Data(contentsOf: url)
            guard let decrypted = cryptoService.decryptLocalData(encrypted) else {
                recordChatHistoryLoadFailure(url, reason: "解密失败")
                return [:]
            }
            let messages = try JSONDecoder().decode([UUID: [P2PChatMessage]].self, from: decrypted)
            chatHistoryLoadFailed = false
            return messages
        } catch {
            recordChatHistoryLoadFailure(url, reason: "读取或 JSON 解码失败：\(error.localizedDescription)")
            return [:]
        }
    }

    private func loadEncryptedGroupMessages(from url: URL) -> [UUID: [P2PGroupMessage]] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            groupHistoryLoadFailed = false
            return [:]
        }

        do {
            let encrypted = try Data(contentsOf: url)
            guard let decrypted = cryptoService.decryptLocalData(encrypted) else {
                recordGroupHistoryLoadFailure(url, reason: "解密失败")
                return [:]
            }
            let messages = try JSONDecoder().decode([UUID: [P2PGroupMessage]].self, from: decrypted)
            groupHistoryLoadFailed = false
            return messages
        } catch {
            recordGroupHistoryLoadFailure(url, reason: "读取或 JSON 解码失败：\(error.localizedDescription)")
            return [:]
        }
    }

    private func recordChatHistoryLoadFailure(_ url: URL, reason: String) {
        chatHistoryLoadFailed = true
        storageService.reportStorageIntegrityIssue(for: url, reason: "P2P 聊天记录\(reason)")
    }

    private func recordGroupHistoryLoadFailure(_ url: URL, reason: String) {
        groupHistoryLoadFailed = true
        storageService.reportStorageIntegrityIssue(for: url, reason: "P2P群聊记录\(reason)")
    }

    private func setupNetworkHandlers() {
        networkService.onMessageReceived = { [weak self] connID, data in
            self?.handleReceivedData(connID, data: data)
        }
        networkService.onConnectionStatusChanged = { [weak self] connID, state in
            self?.handleConnectionStatusChanged(connID, state: state)
        }
        networkService.onConnectionError = { [weak self] _, message in
            DispatchQueue.main.async {
                self?.handleNetworkError(message)
            }
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

        if isBackgroundEnabled {
            _ = networkService.startListening(port: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                var updated = identity
                updated.ipv6Address = self.networkService.localIPv6Address
                updated.port = self.networkService.localPort
                self.currentIdentity = updated
                self.storageService.saveP2PIdentity(updated)
            }
        } else {
            networkService.stopListening()
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
        friends = []
        groups = []
        blackList = []
        pendingConnections = []
        chatMessages = [:]
        groupMessages = [:]
        connToFriendMap = [:]
        pendingConnectionMap = [:]
        legacyMessageIDs = []
        trustedPeerIDs = []
        blockedPeerIDs = []
        securityAlert = nil
        storageService.deleteP2PIdentity()
        storageService.deleteAllP2PFriends()
        storageService.deleteP2PBlackList()
        storageService.deleteAllP2PGroups()

        do {
            if FileManager.default.fileExists(atPath: storageService.p2pMessagesFileURL.path) {
                try FileManager.default.removeItem(at: storageService.p2pMessagesFileURL)
            }
            chatHistoryLoadFailed = false
        } catch {
            print("[P2P] 聊天记录清理失败，保留禁止写回状态：\(error.localizedDescription)")
        }

        do {
            if FileManager.default.fileExists(atPath: storageService.p2pGroupMessagesFileURL.path) {
                try FileManager.default.removeItem(at: storageService.p2pGroupMessagesFileURL)
            }
            groupHistoryLoadFailed = false
        } catch {
            print("[P2P] 群聊记录清理失败，保留禁止写回状态：\(error.localizedDescription)")
        }
    }

    // MARK: - Connection

    /// Connect to a peer. `friendID` should be the existing `P2PFriend.id` if
    /// reconnecting, nil for new connections.
    func connectToFriend(ipv6Address: String, port: Int, friendID: UUID? = nil) -> UUID? {
        guard port > 0, port <= Int(UInt16.max) else { return nil }
        for ip in blackList {
            if ipv6Address.hasPrefix(ip.ipv6Address) { return nil }
        }
        let connID = friendID ?? UUID()
        guard networkService.connectToPeer(
            ipv6Address: ipv6Address,
            port: UInt16(port),
            friendID: connID
        ) else {
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

    /// Explicitly confirms a first-seen fingerprint and persists the public key
    /// in the existing friends JSON file. No automatic trust is granted here.
    func acceptPendingConnection(_ pending: P2PPendingConnection) {
        guard let currentPending = pendingConnections.first(where: { $0.id == pending.id }),
              currentPending.publicKey == pending.publicKey,
              let connID = pendingConnectionMap[pending.id] ?? (networkService.connections[pending.id] != nil ? pending.id : nil),
              let connection = networkService.connections[connID],
              connection.peerIdentityID == pending.id,
              connection.peerPublicKey == pending.publicKey,
              let keyMaterial = connection.keyMaterial else {
            postSecurityAlert(title: "无法确认身份", message: "连接已失效，不能确认该指纹。")
            return
        }

        let fingerprint = cryptoService.fingerprint(forPublicKey: pending.publicKey)
        guard fingerprint != "无效公钥", connection.peerFingerprint == fingerprint else {
            rejectMismatchedPeer(pending.id, connID: connID)
            return
        }

        switch trustDecision(for: pending.id, publicKey: pending.publicKey, fingerprint: fingerprint) {
        case .mismatch:
            rejectMismatchedPeer(pending.id, connID: connID)
            return
        case .trusted, .needsConfirmation:
            if let index = friends.firstIndex(where: { $0.id == pending.id }) {
                // A matching existing public key is already trusted. An empty
                // legacy record is the one case that can be upgraded, but only
                // through this explicit confirmation action.
                if friends[index].publicKey.isEmpty {
                    friends[index].publicKey = pending.publicKey
                    storageService.saveP2PFriends(friends)
                } else if friends[index].publicKey != pending.publicKey {
                    rejectMismatchedPeer(pending.id, connID: connID)
                    return
                }
            } else {
                let friend = P2PFriend(
                    id: pending.id,
                    nickname: pending.nickname,
                    ipv6Address: pending.ipv6Address,
                    port: pending.port,
                    publicKey: pending.publicKey
                )
                friends.append(friend)
                storageService.saveP2PFriends(friends)
            }
        }

        connection.keyMaterial = keyMaterial
        connection.peerIdentityID = pending.id
        connection.peerPublicKey = pending.publicKey
        connection.peerFingerprint = fingerprint
        connection.handshakeCompleted = true
        connection.trustState = .trusted
        connToFriendMap[connID] = pending.id
        trustedPeerIDs.insert(pending.id)
        blockedPeerIDs.remove(pending.id)
        pendingConnections.removeAll { $0.id == pending.id }
        pendingConnectionMap.removeValue(forKey: pending.id)
        connectionStatus[pending.id] = .online
        addSystemMessage(friendID: pending.id, content: "已确认身份并连接")
    }

    func rejectPendingConnection(_ pending: P2PPendingConnection) {
        if let connID = pendingConnectionMap.removeValue(forKey: pending.id) {
            networkService.disconnect(friendID: connID)
        } else {
            networkService.disconnect(friendID: pending.id)
        }
        pendingConnections.removeAll { $0.id == pending.id }
        blockedPeerIDs.remove(pending.id)
    }

    // MARK: - Identity helpers exposed to the P2P UI

    func fingerprint(forPublicKey publicKey: String) -> String {
        cryptoService.fingerprint(forPublicKey: publicKey)
    }

    func isPeerTrusted(_ peerID: UUID) -> Bool {
        trustedPeerIDs.contains(peerID)
    }

    func canSendToFriend(_ friendID: UUID) -> Bool {
        guard trustedPeerIDs.contains(friendID),
              let connID = connectionID(forFriendID: friendID),
              let connection = networkService.connections[connID] else {
            return false
        }
        return connection.handshakeCompleted && connection.trustState == .trusted
    }

    func dismissSecurityAlert() {
        securityAlert = nil
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
        let connID = connectionID(forFriendID: friendID) ?? friendID

        guard let connection = networkService.connections[connID],
              connection.handshakeCompleted,
              connection.trustState == .trusted,
              trustedPeerIDs.contains(friendID),
              let keyMaterial = connection.keyMaterial,
              let messageData = content.data(using: .utf8) else {
            var msg = message
            msg.status = .failed
            appendChatMessage(msg)
            postSecurityAlert(title: "无法发送", message: "对方身份尚未确认或会话密钥不可用，已阻止发送。")
            return
        }

        let encryptedData: Data
        do {
            encryptedData = try cryptoService.encryptMessage(messageData, using: keyMaterial)
        } catch {
            var msg = message
            msg.status = .failed
            appendChatMessage(msg)
            postSecurityAlert(title: "加密失败", message: "消息未发送：\(error.localizedDescription)")
            return
        }

        var packet = Data([P2PPacketType.chatMessage.rawValue])
        packet.append(encryptedData)

        if sendValidatedPacket(packet, to: connID, completion: { [weak self] success in
            guard !success else { return }
            DispatchQueue.main.async {
                self?.markChatMessageFailed(messageID: message.id, friendID: friendID)
            }
        }) {
            var msg = message
            msg.status = .sent
            appendChatMessage(msg)
            updateFriendPreview(friendID: friendID, content: content)
        } else {
            var msg = message
            msg.status = .failed
            appendChatMessage(msg)
        }
    }

    /// Re-sends a message that was received in the legacy CBC format using the
    /// current authenticated GCM format. It is explicit because the local
    /// history does not otherwise retain the original wire envelope.
    @discardableResult
    func reEncryptLegacyMessage(_ message: P2PChatMessage, to friendID: UUID) -> Bool {
        guard legacyMessageIDs.contains(message.id),
              let connectionID = connectionID(forFriendID: friendID),
              let connection = networkService.connections[connectionID],
              connection.handshakeCompleted,
              connection.trustState == .trusted,
              let keyMaterial = connection.keyMaterial,
              let plaintext = message.content.data(using: .utf8),
              let encrypted = try? cryptoService.encryptMessage(plaintext, using: keyMaterial) else {
            return false
        }

        var packet = Data([P2PPacketType.chatMessage.rawValue])
        packet.append(encrypted)
        let sent = sendValidatedPacket(packet, to: connectionID, completion: { [weak self] success in
            if success {
                DispatchQueue.main.async { self?.legacyMessageIDs.remove(message.id) }
            }
        })
        return sent
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
            guard let connID = connectionID(forFriendID: memberID),
                  let connection = networkService.connections[connID],
                  connection.handshakeCompleted,
                  connection.trustState == .trusted,
                  trustedPeerIDs.contains(memberID),
                  let keyMaterial = connection.keyMaterial,
                  let messageData = content.data(using: .utf8),
                  let encryptedData = try? cryptoService.encryptMessage(messageData, using: keyMaterial) else {
                continue
            }
            var packet = Data([P2PPacketType.groupMessage.rawValue])
            packet.append(groupID.uuidString.data(using: .utf8) ?? Data())
            packet.append(encryptedData)
            _ = sendValidatedPacket(packet, to: connID)
        }
    }

    // MARK: - Background

    func setBackgroundEnabled(_ enabled: Bool) {
        isBackgroundEnabled = enabled
        let settings = storageService.loadSettings()
        settings.p2pBackgroundEnabled = enabled
        storageService.saveSettings(settings)

        if enabled {
            if let identity = currentIdentity {
                _ = networkService.startListening(port: UInt16(identity.port > 0 ? identity.port : 0))
            }
        } else {
            // DisconnectAll alone used to leave NWListener alive and the port
            // open. Stop the listener itself before tearing down connections.
            networkService.stopListening()
            networkService.disconnectAll()
        }
    }

    // MARK: - Packet Handling

    private func handleReceivedData(_ connID: UUID, data: Data) {
        // `data` is one complete frame from P2PFrameAssembler; it is not a raw
        // TCP read. Validate type and all field lengths before dispatching.
        switch P2PProtocolCodec.validatePacket(data) {
        case .failure(let error):
            reportProtocolError(connID: connID, error: error)
        case .success(let parsed):
            switch parsed.0 {
            case .handshake:
                handleHandshake(connID, data: parsed.1)
            case .handshakeAck:
                handleHandshakeAck(connID, data: parsed.1)
            case .chatMessage:
                handleChatMessage(connID, data: parsed.1)
            case .groupMessage:
                handleGroupMessage(connID, data: parsed.1)
            case .statusMessage:
                handleStatusMessage(connID, data: parsed.1)
            }
        }
    }

    // MARK: - Handshake and identity verification

    private func handleHandshake(_ connID: UUID, data: Data) {
        guard currentIdentity != nil else { return }
        guard case .success(let info) = P2PProtocolCodec.parseHandshakePayload(data),
              cryptoService.isValidPublicKey(info.publicKey) else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            return
        }
        guard let connection = networkService.connections[connID] else { return }
        guard !connection.isOutgoing else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            networkService.disconnect(friendID: connID)
            return
        }
        guard connection.peerIdentityID == nil else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            networkService.disconnect(friendID: connID)
            return
        }

        let fingerprint = cryptoService.fingerprint(forPublicKey: info.publicKey)
        guard fingerprint != "无效公钥" else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            return
        }
        connection.peerIdentityID = info.identityID
        connection.peerPublicKey = info.publicKey
        connection.peerFingerprint = fingerprint
        connToFriendMap[connID] = info.identityID

        switch trustDecision(for: info.identityID, publicKey: info.publicKey, fingerprint: fingerprint) {
        case .mismatch:
            rejectMismatchedPeer(info.identityID, connID: connID)
            return
        case .trusted, .needsConfirmation:
            break
        }

        let rawKey = cryptoService.generateAESKey()
        let keyVersion = info.capabilityVersion == nil
            ? P2PKeyMaterial.legacyCBCVersion
            : P2PKeyMaterial.currentVersion
        guard let keyMaterial = try? P2PKeyMaterial(rawKey: rawKey, version: keyVersion),
              let encryptedKey = cryptoService.encryptWithPublicKey(
                rawKey,
                publicKeyString: info.publicKey
              ) else {
            postSecurityAlert(title: "握手失败", message: "无法为对方生成会话密钥，连接未建立信任。")
            networkService.disconnect(friendID: connID)
            return
        }

        connection.keyMaterial = keyMaterial
        connection.trustState = .unverified
        guard sendHandshakeAck(
            to: connID,
            encryptedKey: encryptedKey,
            keyVersion: keyMaterial.version
        ) else {
            postSecurityAlert(title: "握手失败", message: "会话密钥确认帧发送失败，连接未建立信任。")
            networkService.disconnect(friendID: connID)
            return
        }

        if isTrustedPeer(info.identityID) {
            activateTrustedConnection(connID: connID, peerID: info.identityID)
        } else {
            queuePendingConnection(
                id: info.identityID,
                nickname: info.nickname,
                publicKey: info.publicKey,
                connID: connID
            )
        }
    }

    private func handleHandshakeAck(_ connID: UUID, data: Data) {
        guard let identity = currentIdentity else { return }
        guard case .success(let ack) = P2PProtocolCodec.parseHandshakeAckPayload(data),
              cryptoService.isValidPublicKey(ack.identity.publicKey) else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            return
        }
        guard let connection = networkService.connections[connID] else { return }
        guard connection.isOutgoing else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            networkService.disconnect(friendID: connID)
            return
        }
        guard connection.peerIdentityID == nil else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            networkService.disconnect(friendID: connID)
            return
        }

        let fingerprint = cryptoService.fingerprint(forPublicKey: ack.identity.publicKey)
        guard fingerprint != "无效公钥" else {
            reportProtocolError(connID: connID, error: .malformedHandshake)
            return
        }
        connection.peerIdentityID = ack.identity.identityID
        connection.peerPublicKey = ack.identity.publicKey
        connection.peerFingerprint = fingerprint
        connToFriendMap[connID] = ack.identity.identityID

        switch trustDecision(
            for: ack.identity.identityID,
            publicKey: ack.identity.publicKey,
            fingerprint: fingerprint
        ) {
        case .mismatch:
            rejectMismatchedPeer(ack.identity.identityID, connID: connID)
            return
        case .trusted, .needsConfirmation:
            break
        }

        guard let rawKey = cryptoService.decryptWithPrivateKey(
            ack.encryptedKey,
            privateKeyRef: identity.privateKeyRef
        ) else {
            postSecurityAlert(title: "握手失败", message: "无法解密对端会话密钥，连接未建立信任。")
            networkService.disconnect(friendID: connID)
            return
        }

        let version = ack.keyVersion ?? P2PKeyMaterial.legacyCBCVersion
        guard let keyMaterial = try? P2PKeyMaterial(rawKey: rawKey, version: version) else {
            postSecurityAlert(title: "握手失败", message: "对端会话密钥版本不受支持。")
            networkService.disconnect(friendID: connID)
            return
        }
        connection.keyMaterial = keyMaterial
        connection.trustState = .unverified

        if isTrustedPeer(ack.identity.identityID) {
            activateTrustedConnection(connID: connID, peerID: ack.identity.identityID)
        } else {
            queuePendingConnection(
                id: ack.identity.identityID,
                nickname: ack.identity.nickname,
                publicKey: ack.identity.publicKey,
                connID: connID
            )
        }
    }

    private func trustDecision(for peerID: UUID,
                               publicKey: String,
                               fingerprint: String) -> PeerTrustDecision {
        var recordedPublicKeys: [UUID: String] = [:]
        for friend in friends {
            recordedPublicKeys[friend.id] = friend.publicKey
        }
        let decision = P2PPeerTrustPolicy.evaluate(
            peerID: peerID,
            presentedPublicKey: publicKey,
            presentedFingerprint: fingerprint,
            recordedPublicKeys: recordedPublicKeys,
            fingerprintForKey: { [weak self] key in
                self?.cryptoService.fingerprint(forPublicKey: key) ?? "无效公钥"
            }
        )
        switch decision {
        case .trusted: return .trusted
        case .needsConfirmation: return .needsConfirmation
        case .mismatch: return .mismatch
        }
    }

    private func isTrustedPeer(_ peerID: UUID) -> Bool {
        guard let connection = networkService.connections.values.first(where: { $0.peerIdentityID == peerID }),
              let publicKey = connection.peerPublicKey,
              let fingerprint = connection.peerFingerprint else {
            return false
        }
        if case .trusted = trustDecision(for: peerID, publicKey: publicKey, fingerprint: fingerprint) {
            return true
        }
        return false
    }

    private func queuePendingConnection(id: UUID,
                                        nickname: String,
                                        publicKey: String,
                                        connID: UUID) {
        if let existing = pendingConnections.first(where: { $0.id == id }) {
            guard existing.publicKey == publicKey else {
                postSecurityAlert(
                    title: "指纹冲突",
                    message: "对方身份与已记录指纹不一致，已阻止建立信任。"
                )
                blockedPeerIDs.insert(id)
                networkService.disconnect(friendID: connID)
                return
            }
        } else {
            pendingConnections.append(P2PPendingConnection(
                id: id,
                nickname: nickname,
                publicKey: publicKey,
                ipv6Address: "",
                port: 0
            ))
        }
        pendingConnectionMap[id] = connID
        connectionStatus[id] = .offline
    }

    private func activateTrustedConnection(connID: UUID, peerID: UUID) {
        guard let connection = networkService.connections[connID] else { return }
        connection.handshakeCompleted = true
        connection.trustState = .trusted
        connToFriendMap[connID] = peerID
        trustedPeerIDs.insert(peerID)
        blockedPeerIDs.remove(peerID)
        pendingConnections.removeAll { $0.id == peerID }
        pendingConnectionMap.removeValue(forKey: peerID)
        connectionStatus[peerID] = .online
        if !friends.contains(where: { $0.id == peerID }) {
            addSystemMessage(friendID: peerID, content: "对端身份已确认")
        } else {
            addSystemMessage(friendID: peerID, content: "已连接")
        }
    }

    private func rejectMismatchedPeer(_ peerID: UUID, connID: UUID) {
        trustedPeerIDs.remove(peerID)
        blockedPeerIDs.insert(peerID)
        if let connection = networkService.connections[connID] {
            connection.handshakeCompleted = false
            connection.trustState = .blocked
        }
        pendingConnections.removeAll { $0.id == peerID }
        pendingConnectionMap.removeValue(forKey: peerID)
        connectionStatus[peerID] = .offline
        networkService.disconnect(friendID: connID)
        postSecurityAlert(
            title: "身份校验失败",
            message: "对方身份与已记录指纹不一致，已拒绝建立信任并阻止发送消息。"
        )
    }

    private func decryptionFailureMessage(_ error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if detail.contains("AES-GCM") {
            return "消息解密失败（认证标签不匹配、密文被篡改或会话密钥错误），未返回任何明文。"
        }
        return "消息解密失败：\(detail)，未返回任何明文。"
    }

    private func handleNetworkError(_ message: String) {
        print("[P2P] Network: \(message)")
        if message.contains("帧") || message.contains("协议") {
            postSecurityAlert(title: "连接协议错误", message: message)
        }
    }

    // MARK: - Handshake encoding

    /// 按完整 Character 截断昵称，确保 UTF-8 数据不超过长度字段限制。
    private func nicknameDataForPacket(_ nickname: String) -> Data {
        P2PNicknameCodec.packetData(for: nickname, maximumByteCount: 255)
    }

    private func sendValidatedPacket(_ packet: Data,
                                     to connID: UUID,
                                     completion: ((Bool) -> Void)? = nil) -> Bool {
        switch P2PProtocolCodec.validatePacket(packet) {
        case .failure(let error):
            reportProtocolError(connID: connID, error: error)
            completion?(false)
            return false
        case .success:
            return networkService.send(packet, to: connID, completion: completion)
        }
    }

    private func sendHandshake(to connID: UUID) {
        guard let identity = currentIdentity,
              let connection = networkService.connections[connID],
              !connection.handshakeSent else { return }
        let nicknameData = nicknameDataForPacket(identity.nickname)
        let pubKeyData = identity.publicKey.data(using: .utf8) ?? Data()
        guard !nicknameData.isEmpty,
              !pubKeyData.isEmpty,
              pubKeyData.count <= Int(UInt16.max) else { return }

        var packet = Data([P2PPacketType.handshake.rawValue])
        packet.append(identity.id.uuidString.data(using: .utf8) ?? Data())
        packet.append(UInt8(nicknameData.count))
        packet.append(nicknameData)
        packet.append(UInt16(pubKeyData.count).bigEndian.data)
        packet.append(pubKeyData)
        // Legacy peers ignore this trailing capability byte; new peers use it
        // to distinguish a legacy CBC session from a current GCM session.
        packet.append(P2PProtocolCodec.currentCapabilityVersion)

        connection.handshakeSent = sendValidatedPacket(packet, to: connID)
        if connection.handshakeSent {
            print("[P2P] Sent handshake on conn \(connID)")
        }
    }

    private func sendHandshakeAck(to connID: UUID,
                                  encryptedKey: Data,
                                  keyVersion: UInt8) -> Bool {
        guard let identity = currentIdentity else { return false }
        let nicknameData = nicknameDataForPacket(identity.nickname)
        let pubKeyData = identity.publicKey.data(using: .utf8) ?? Data()
        guard !nicknameData.isEmpty,
              !pubKeyData.isEmpty,
              pubKeyData.count <= Int(UInt16.max) else { return false }

        var packet = Data([P2PPacketType.handshakeAck.rawValue])
        packet.append(identity.id.uuidString.data(using: .utf8) ?? Data())
        packet.append(UInt8(nicknameData.count))
        packet.append(nicknameData)
        packet.append(UInt16(pubKeyData.count).bigEndian.data)
        packet.append(pubKeyData)
        packet.append(encryptedKey)
        // The version is outside the RSA ciphertext so an old peer can still
        // consume the first 256 bytes. New peers reject unknown versions.
        packet.append(keyVersion)

        let sent = sendValidatedPacket(packet, to: connID)
        if sent { print("[P2P] Sent handshake ack on conn \(connID)") }
        return sent
    }

    // MARK: - Message Handlers

    private func handleChatMessage(_ connID: UUID, data: Data) {
        guard let connection = networkService.connections[connID],
              let keyMaterial = connection.keyMaterial else { return }
        let fid = friendID(for: connID)
        guard isTrustedConnection(connID: connID, peerID: fid) else {
            print("[P2P] Dropped chat from unverified peer \(fid)")
            return
        }

        let decryptedData: Data
        do {
            decryptedData = try cryptoService.decryptMessage(data, using: keyMaterial)
        } catch {
            postSecurityAlert(title: "消息已拒绝", message: decryptionFailureMessage(error))
            return
        }
        guard let content = String(data: decryptedData, encoding: .utf8) else {
            postSecurityAlert(title: "消息已拒绝", message: "解密结果不是有效 UTF-8，消息已丢弃。")
            return
        }

        let message = P2PChatMessage(friendID: fid, content: content, isSent: false, status: .delivered)
        if cryptoService.isLegacyCBCMessage(data) {
            legacyMessageIDs.insert(message.id)
        }
        appendChatMessage(message)
        updateFriendPreview(friendID: fid, content: content)
        updateFriendTimestamp(friendID: fid)
    }

    private func handleGroupMessage(_ connID: UUID, data: Data) {
        guard let connection = networkService.connections[connID],
              let keyMaterial = connection.keyMaterial else { return }
        let fid = friendID(for: connID)
        guard isTrustedConnection(connID: connID, peerID: fid) else { return }
        guard data.count > P2PProtocolCodec.uuidByteCount else { return }
        let groupIDString = String(data: data.prefix(P2PProtocolCodec.uuidByteCount), encoding: .utf8) ?? ""
        guard let groupID = UUID(uuidString: groupIDString) else { return }
        let encryptedData = Data(data.dropFirst(P2PProtocolCodec.uuidByteCount))

        let decryptedData: Data
        do {
            decryptedData = try cryptoService.decryptMessage(encryptedData, using: keyMaterial)
        } catch {
            postSecurityAlert(title: "群聊消息已拒绝", message: decryptionFailureMessage(error))
            return
        }
        guard let content = String(data: decryptedData, encoding: .utf8) else {
            postSecurityAlert(title: "群聊消息已拒绝", message: "解密结果不是有效 UTF-8，消息已丢弃。")
            return
        }

        let senderNickname = friends.first(where: { $0.id == fid })?.nickname ?? "Unknown"
        let message = P2PGroupMessage(groupID: groupID, senderNickname: senderNickname, content: content)
        appendGroupMessage(message)
    }

    private func handleStatusMessage(_ connID: UUID, data: Data) {
        guard let connection = networkService.connections[connID],
              let keyMaterial = connection.keyMaterial else { return }
        let fid = friendID(for: connID)
        guard isTrustedConnection(connID: connID, peerID: fid) else { return }

        do {
            let decryptedData = try cryptoService.decryptMessage(data, using: keyMaterial)
            guard let statusString = String(data: decryptedData, encoding: .utf8),
                  let status = P2PFriend.FriendStatus(rawValue: statusString) else {
                postSecurityAlert(title: "状态消息已拒绝", message: "状态消息格式无效，消息已丢弃。")
                return
            }
            connectionStatus[fid] = status
        } catch {
            postSecurityAlert(title: "状态消息已拒绝", message: decryptionFailureMessage(error))
        }
    }

    // MARK: - Connection Status

    private func handleConnectionStatusChanged(_ connID: UUID, state: NWConnection.State) {
        switch state {
        case .ready:
            if let connection = networkService.connections[connID], connection.isOutgoing {
                sendHandshake(to: connID)
            }
            // Incoming peers send their identity in the handshake frame.
        case .waiting(let error):
            print("[P2P] Connection \(connID) waiting: \(error.localizedDescription)")
        case .failed, .cancelled:
            let fid = friendID(for: connID)
            connectionStatus[fid] = .offline
            trustedPeerIDs.remove(fid)
            pendingConnections.removeAll { $0.id == fid || $0.id == connID }
            pendingConnectionMap.removeValue(forKey: fid)
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
        let msg = P2PChatMessage(
            friendID: friendID,
            content: content,
            isSent: true,
            status: .delivered,
            type: .system
        )
        appendChatMessage(msg)
    }

    private func markChatMessageFailed(messageID: UUID, friendID: UUID) {
        guard let index = chatMessages[friendID]?.firstIndex(where: { $0.id == messageID }) else { return }
        chatMessages[friendID]?[index].status = .failed
        saveChatMessages()
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
        guard !chatHistoryLoadFailed else {
            print("[P2P] 跳过聊天记录写入：原文件读取失败，已保留隔离副本")
            return
        }

        do {
            let data = try JSONEncoder().encode(chatMessages)
            guard let encrypted = cryptoService.encryptLocalData(data) else {
                print("[P2P] 聊天记录加密失败，未写入原文件")
                return
            }
            try encrypted.write(to: storageService.p2pMessagesFileURL, options: .atomic)
        } catch {
            print("[P2P] 聊天记录保存失败 \(storageService.p2pMessagesFileURL)：\(error.localizedDescription)")
        }
    }

    private func saveGroupMessages() {
        guard !groupHistoryLoadFailed else {
            print("[P2P] 跳过聊天记录写入：原文件读取失败，已保留隔离副本")
            return
        }

        do {
            let data = try JSONEncoder().encode(groupMessages)
            guard let encrypted = cryptoService.encryptLocalData(data) else {
                print("[P2P] 群聊记录加密失败，未写入原文件")
                return
            }
            try encrypted.write(to: storageService.p2pGroupMessagesFileURL, options: .atomic)
        } catch {
            print("[P2P] 群聊记录保存失败 \(storageService.p2pGroupMessagesFileURL)：\(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    func getIPv6Address() -> String { networkService.localIPv6Address }
    func getPort() -> Int { networkService.localPort }

    private func connectionID(forFriendID friendID: UUID) -> UUID? {
        if let connID = connToFriendMap.first(where: { $0.value == friendID })?.key {
            return connID
        }
        return networkService.connections[friendID] != nil ? friendID : nil
    }

    private func isTrustedConnection(connID: UUID, peerID: UUID) -> Bool {
        guard let connection = networkService.connections[connID] else { return false }
        return connection.handshakeCompleted
            && connection.trustState == .trusted
            && trustedPeerIDs.contains(peerID)
    }

    private func canonicalFingerprint(for publicKeyData: Data) -> String? {
        guard cryptoService.isValidPublicKey(publicKeyData.base64EncodedString()) else { return nil }
        let fingerprint = cryptoService.fingerprint(forPublicKey: publicKeyData.base64EncodedString())
        return fingerprint == "无效公钥" ? nil : fingerprint
    }

    private func postSecurityAlert(title: String, message: String) {
        let alert = P2PSecurityAlert(title: title, message: message)
        if Thread.isMainThread {
            securityAlert = alert
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.securityAlert = alert
            }
        }
    }

    private func reportProtocolError(connID: UUID, error: P2PProtocolError) {
        print("[P2P] Dropped invalid packet on \(connID): \(error.localizedDescription)")
        postSecurityAlert(title: "协议错误", message: "已丢弃边界无效的数据包：\(error.localizedDescription)")
    }
}

private enum PeerTrustDecision {
    case trusted
    case needsConfirmation
    case mismatch
}

extension UInt16 {
    var data: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt16>.size)
    }
}
