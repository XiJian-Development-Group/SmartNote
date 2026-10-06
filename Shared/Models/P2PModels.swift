import Foundation

struct P2PUserIdentity: Codable, Identifiable {
    let id: UUID
    var nickname: String
    var avatarData: Data?
    var signature: String
    var publicKey: String
    var privateKeyRef: String
    var keyFingerprint: String
    var ipv6Address: String
    var port: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        nickname: String,
        avatarData: Data? = nil,
        signature: String = "",
        publicKey: String = "",
        privateKeyRef: String = "",
        keyFingerprint: String = "",
        ipv6Address: String = "",
        port: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.nickname = nickname
        self.avatarData = avatarData
        self.signature = signature
        self.publicKey = publicKey
        self.privateKeyRef = privateKeyRef
        self.keyFingerprint = keyFingerprint
        self.ipv6Address = ipv6Address
        self.port = port
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct P2PFriend: Codable, Identifiable {
    let id: UUID
    var nickname: String
    var remark: String
    var ipv6Address: String
    var port: Int
    var publicKey: String
    var avatarData: Data?
    var status: FriendStatus
    var addedAt: Date
    var lastMessageAt: Date?
    var lastMessagePreview: String?

    enum FriendStatus: String, Codable {
        case online
        case offline
        case focusing
    }

    init(
        id: UUID = UUID(),
        nickname: String,
        remark: String = "",
        ipv6Address: String = "",
        port: Int = 0,
        publicKey: String,
        avatarData: Data? = nil,
        status: FriendStatus = .offline,
        addedAt: Date = Date(),
        lastMessageAt: Date? = nil,
        lastMessagePreview: String? = nil
    ) {
        self.id = id
        self.nickname = nickname
        self.remark = remark
        self.ipv6Address = ipv6Address
        self.port = port
        self.publicKey = publicKey
        self.avatarData = avatarData
        self.status = status
        self.addedAt = addedAt
        self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview
    }
}

struct P2PChatMessage: Codable, Identifiable {
    let id: UUID
    var friendID: UUID
    var content: String
    var isSent: Bool
    var status: MessageStatus
    var timestamp: Date
    var type: MessageType

    enum MessageStatus: String, Codable {
        case sending
        case sent
        case delivered
        case failed
    }

    enum MessageType: String, Codable {
        case text
        case file
        case status
        case system
    }

    init(
        id: UUID = UUID(),
        friendID: UUID,
        content: String,
        isSent: Bool,
        status: MessageStatus = .sending,
        timestamp: Date = Date(),
        type: MessageType = .text
    ) {
        self.id = id
        self.friendID = friendID
        self.content = content
        self.isSent = isSent
        self.status = status
        self.timestamp = timestamp
        self.type = type
    }
}

struct P2PGroup: Codable, Identifiable {
    let id: UUID
    var name: String
    var memberIDs: [UUID]
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        memberIDs: [UUID],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.memberIDs = memberIDs
        self.createdAt = createdAt
    }
}

struct P2PGroupMessage: Codable, Identifiable {
    let id: UUID
    let groupID: UUID
    let senderNickname: String
    var content: String
    var timestamp: Date

    init(
        id: UUID = UUID(),
        groupID: UUID,
        senderNickname: String,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.groupID = groupID
        self.senderNickname = senderNickname
        self.content = content
        self.timestamp = timestamp
    }
}

struct P2PPendingConnection: Identifiable {
    let id: UUID
    let nickname: String
    let publicKey: String
    let ipv6Address: String
    let port: Int
    let timestamp: Date

    init(
        id: UUID,
        nickname: String,
        publicKey: String,
        ipv6Address: String,
        port: Int,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.nickname = nickname
        self.publicKey = publicKey
        self.ipv6Address = ipv6Address
        self.port = port
        self.timestamp = timestamp
    }
}

struct P2PBlackIP: Codable, Identifiable {
    let id: UUID
    var ipv6Address: String
    var reason: String
    var blockedAt: Date

    init(
        id: UUID = UUID(),
        ipv6Address: String,
        reason: String = "",
        blockedAt: Date = Date()
    ) {
        self.id = id
        self.ipv6Address = ipv6Address
        self.reason = reason
        self.blockedAt = blockedAt
    }
}

enum UserStatus: String, Codable {
    case online
    case focusing
    case offline
}

enum P2PPacketType: UInt8 {
    case chatMessage = 0x01
    case statusMessage = 0x02
    case groupMessage = 0x03
    case handshake = 0x10
    case handshakeAck = 0x11
}
