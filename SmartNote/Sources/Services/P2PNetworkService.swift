import Foundation
import Network
import Combine
import Darwin

/// A side-effect-free length-prefix frame implementation used by the socket
/// layer and by the standalone P2P probe. A frame is `[UInt32 big-endian
/// payload length][payload]`; zero and lengths above the limit are rejected.
///
/// The transport remains plain TCP. Framing only prevents TCP read-boundary
/// errors; it does not provide TLS, replay protection, or downgrade protection.
enum P2PFrameError: Error, Equatable, LocalizedError {
    case emptyPayload
    case frameTooLarge(received: UInt32, maximum: Int)
    case invalidLengthPrefix
    case incompleteFrame

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "帧负载不能为空"
        case .frameTooLarge(let received, let maximum):
            return "帧长度 \(received) 超过上限 \(maximum)"
        case .invalidLengthPrefix:
            return "帧长度前缀无效"
        case .incompleteFrame:
            return "帧不完整"
        }
    }
}

struct P2PFrameAssembler {
    static let defaultMaximumFrameLength = 8 * 1024 * 1024

    let maximumFrameLength: Int
    private(set) var buffer = Data()

    init(maximumFrameLength: Int = P2PFrameAssembler.defaultMaximumFrameLength) {
        self.maximumFrameLength = max(1, maximumFrameLength)
    }

    var hasPartialFrame: Bool { !buffer.isEmpty }
    var bufferedByteCount: Int { buffer.count }

    /// Appends arbitrary TCP bytes and returns every complete frame currently
    /// available. It deliberately keeps the prefix until enough payload bytes
    /// have arrived, so split reads and coalesced reads have identical results.
    mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        var frames: [Data] = []

        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(UInt32(0)) { partial, byte in
                (partial << 8) | UInt32(byte)
            }

            guard length > 0 else {
                reset()
                throw P2PFrameError.invalidLengthPrefix
            }
            guard length <= UInt32(maximumFrameLength) else {
                let received = length
                reset()
                throw P2PFrameError.frameTooLarge(received: received, maximum: maximumFrameLength)
            }

            let payloadLength = Int(length)
            let frameLength = 4 + payloadLength
            guard buffer.count >= frameLength else { break }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: 4)
            let payloadEnd = buffer.index(payloadStart, offsetBy: payloadLength)
            frames.append(Data(buffer[payloadStart..<payloadEnd]))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }

        return frames
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}

enum P2PNicknameCodec {
    /// The handshake length is one byte, but it counts UTF-8 bytes. Truncate
    /// on Character boundaries so a multi-byte character is never split.
    static func packetData(for nickname: String, maximumByteCount: Int = 255) -> Data {
        var result = Data()
        for character in nickname {
            let characterData = String(character).data(using: .utf8) ?? Data()
            guard result.count + characterData.count <= maximumByteCount else { break }
            result.append(characterData)
        }
        return result
    }
}

enum P2PFrameCodec {
    static let maximumFrameLength = P2PFrameAssembler.defaultMaximumFrameLength

    static func encode(_ payload: Data,
                       maximumFrameLength: Int = P2PFrameCodec.maximumFrameLength) throws -> Data {
        guard !payload.isEmpty else { throw P2PFrameError.emptyPayload }
        guard payload.count <= maximumFrameLength else {
            throw P2PFrameError.frameTooLarge(received: UInt32(clamping: payload.count), maximum: maximumFrameLength)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(payload)
        return frame
    }

    /// Convenience pure decoder for tests and non-Network callers. It accepts
    /// a stream chunk and therefore may return only the complete prefix.
    static func decode(_ data: Data,
                       maximumFrameLength: Int = P2PFrameCodec.maximumFrameLength) throws -> [Data] {
        var assembler = P2PFrameAssembler(maximumFrameLength: maximumFrameLength)
        return try assembler.append(data)
    }

    /// Decodes a finite buffer and rejects a trailing partial frame.
    static func decodeComplete(_ data: Data,
                               maximumFrameLength: Int = P2PFrameCodec.maximumFrameLength) throws -> [Data] {
        var assembler = P2PFrameAssembler(maximumFrameLength: maximumFrameLength)
        let frames = try assembler.append(data)
        guard !assembler.hasPartialFrame else { throw P2PFrameError.incompleteFrame }
        return frames
    }
}

enum P2PConnectionTrustState: Equatable {
    case unverified
    case trusted
    case blocked
}

/// Per-connection protocol and I/O state. All mutable socket state is touched
/// on P2PNetworkService's serial queue.
final class P2PConnection: Identifiable {
    let id: UUID
    let connection: NWConnection
    let isOutgoing: Bool

    var frameAssembler: P2PFrameAssembler
    var keyMaterial: P2PKeyMaterial?
    var handshakeCompleted = false
    var handshakeSent = false
    var trustState: P2PConnectionTrustState = .unverified

    var peerIdentityID: UUID?
    var peerPublicKey: String?
    var peerFingerprint: String?

    var pendingSendData = Data()
    var activeSendData: Data?
    var activeSendOffset = 0
    var sendInFlight = false
    var sendCompletions: [(Bool) -> Void] = []

    var isTerminated = false
    var userInitiatedClose = false

    /// Kept as a source-compatible bridge for older callers. New code uses the
    /// versioned `keyMaterial` instead of treating raw bytes as the protocol.
    var aesKey: Data? {
        get { keyMaterial?.rawKey }
        set {
            if let newValue = newValue {
                keyMaterial = try? P2PKeyMaterial(rawKey: newValue)
            } else {
                keyMaterial = nil
            }
        }
    }

    init(id: UUID,
         connection: NWConnection,
         isOutgoing: Bool,
         maximumFrameLength: Int = P2PFrameAssembler.defaultMaximumFrameLength) {
        self.id = id
        self.connection = connection
        self.isOutgoing = isOutgoing
        self.frameAssembler = P2PFrameAssembler(maximumFrameLength: maximumFrameLength)
    }
}

final class P2PNetworkService: ObservableObject {
    static let shared = P2PNetworkService()

    @Published var isListening = false
    @Published var localIPv6Address: String = ""
    @Published var localPort: Int = 0
    @Published var connections: [UUID: P2PConnection] = [:]

    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private let queue = DispatchQueue(label: "com.smartnote.p2p", qos: .userInitiated)
    private let maximumSendChunk = 64 * 1024

    /// These callbacks receive complete, unprefixed packet frames. The service
    /// layer therefore never has to guess where a TCP read ended.
    var onMessageReceived: ((UUID, Data) -> Void)?
    var onConnectionStatusChanged: ((UUID, NWConnection.State) -> Void)?
    var onConnectionError: ((UUID, String) -> Void)?
    var onIncomingConnection: ((String, Int) -> Void)?

    private init() {}

    // MARK: - Listener lifecycle

    func startListening(port: UInt16 = 0) -> Bool {
        if listener != nil { return true }

        let generation = UUID()
        listenerGeneration = generation
        do {
            let createdListener = try NWListener(
                using: .tcp,
                on: NWEndpoint.Port(rawValue: port) ?? .any
            )
            listener = createdListener

            // This is deliberately plain TCP. There is no TLS identity/certificate
            // in this peer-to-peer mode; confidentiality and integrity are supplied
            // by the versioned application-layer AES-GCM messages after handshake.
            createdListener.stateUpdateHandler = { [weak self, weak createdListener] state in
                guard let self = self else { return }
                self.queue.async {
                    guard self.listenerGeneration == generation,
                          self.listener === createdListener else { return }
                    switch state {
                    case .ready:
                        self.updateListenerPort()
                        DispatchQueue.main.async { self.isListening = true }
                    case .failed, .cancelled:
                        if self.listener === createdListener {
                            self.listener = nil
                        }
                        DispatchQueue.main.async {
                            self.isListening = false
                            self.localPort = 0
                        }
                    default:
                        break
                    }
                }
            }

            createdListener.newConnectionHandler = { [weak self, weak createdListener] connection in
                guard let self = self else { return }
                self.queue.async {
                    guard self.listenerGeneration == generation,
                          self.listener === createdListener else {
                        connection.cancel()
                        return
                    }
                    // 第一条连接到达即代表 listener 已经真正 ready，
                    // 此时取本机地址才准确。原来固定延迟 1 秒取址，
                    // 设备切网（Wi-Fi ↔ 以太网、IPv6 link-local 重新分配）时会读到旧 IP。
                    self.updateLocalAddress()
                    self.handleIncomingConnection(connection)
                }
            }

            createdListener.start(queue: queue)
            // 启动后立即取一次，作为尚无连接时的初始值；
            // 之后每次有连接进来都会重新取，覆盖这里的快照。
            DispatchQueue.main.async { [weak self] in
                self?.updateLocalAddress()
            }
            return true
        } catch {
            listener = nil
            print("Failed to create listener: \(error)")
            DispatchQueue.main.async { self.isListening = false }
            return false
        }
    }

    /// Cancels the actual NWListener, not just active connections. This is
    /// called when the user turns off background residency.
    func stopListening() {
        let oldListener = listener
        listener = nil
        listenerGeneration = UUID()
        oldListener?.cancel()
        DispatchQueue.main.async { [weak self] in
            self?.isListening = false
            self?.localPort = 0
        }
    }

    private func updateListenerPort() {
        guard let port = listener?.port?.rawValue else { return }
        DispatchQueue.main.async { [weak self] in
            self?.localPort = Int(port)
        }
    }

    private func updateLocalAddress() {
        let params = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: "_tcp", domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.getIPv6Address()
            }
            browser.cancel()
        }

        browser.start(queue: queue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.getIPv6Address()
        }
    }

    private func getIPv6Address() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let interfaceAddress = interface.ifa_addr else { continue }
            let addressFamily = interfaceAddress.pointee.sa_family

            if addressFamily == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("utun") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        interfaceAddress,
                        socklen_t(interfaceAddress.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    guard result == 0 else { continue }

                    let ipv6 = String(cString: hostname)
                    if !ipv6.contains("fe80") && !ipv6.contains("%") {
                        DispatchQueue.main.async { [weak self] in
                            self?.localIPv6Address = ipv6
                        }
                        break
                    }
                }
            }
        }
    }

    // MARK: - Connections

    func connectToPeer(ipv6Address: String, port: UInt16, friendID: UUID) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(ipv6Address),
            port: endpointPort
        )

        // Plain TCP is intentional. Do not imply TLS here: peer certificates and
        // a TLS trust anchor are not available in this deployment.
        let connection = NWConnection(to: endpoint, using: .tcp)
        let p2pConnection = P2PConnection(
            id: friendID,
            connection: connection,
            isOutgoing: true
        )

        connections[friendID] = p2pConnection
        setupConnectionHandlers(p2pConnection)
        return true
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        let tempID = UUID()
        let p2pConnection = P2PConnection(
            id: tempID,
            connection: connection,
            isOutgoing: false
        )

        connections[tempID] = p2pConnection
        setupConnectionHandlers(p2pConnection)

        if let endpoint = connection.currentPath?.remoteEndpoint,
           case .hostPort(let host, let port) = endpoint {
            let hostDescription = host.debugDescription
            let portValue = Int(port.rawValue)
            DispatchQueue.main.async { [weak self] in
                self?.onIncomingConnection?(hostDescription, portValue)
            }
        }
    }

    private func setupConnectionHandlers(_ p2pConnection: P2PConnection) {
        p2pConnection.connection.stateUpdateHandler = { [weak self, weak p2pConnection] state in
            guard let self = self, let p2pConnection = p2pConnection else { return }
            self.queue.async { [weak self] in
                guard let self = self else { return }
                if case .failed(let error) = state {
                    self.terminate(
                        p2pConnection,
                        errorMessage: "连接失败：\(error.localizedDescription)"
                    )
                } else if case .cancelled = state {
                    let partial = p2pConnection.frameAssembler.hasPartialFrame
                    let message = partial
                        ? "连接已断开，已清空不完整接收帧"
                        : "连接已断开，已清空接收缓冲"
                    self.terminate(p2pConnection, errorMessage: message)
                }

                DispatchQueue.main.async { [weak self] in
                    self?.onConnectionStatusChanged?(p2pConnection.id, state)
                }
            }
        }

        p2pConnection.connection.start(queue: queue)
        receiveData(on: p2pConnection)
    }

    private func receiveData(on p2pConnection: P2PConnection) {
        guard !p2pConnection.isTerminated else { return }

        p2pConnection.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak p2pConnection] data, _, isComplete, error in
            guard let self = self, let p2pConnection = p2pConnection else { return }
            self.queue.async { [weak self, weak p2pConnection] in
                guard let self = self, let p2pConnection = p2pConnection else { return }
                guard !p2pConnection.isTerminated else { return }

                if let data = data, !data.isEmpty {
                    do {
                        let frames = try p2pConnection.frameAssembler.append(data)
                        for frame in frames {
                            DispatchQueue.main.async { [weak self] in
                                self?.onMessageReceived?(p2pConnection.id, frame)
                            }
                        }
                    } catch {
                        let message = "帧组装失败：\(error.localizedDescription)"
                        self.terminate(p2pConnection, errorMessage: message)
                        return
                    }
                }

                if let error = error {
                    self.terminate(p2pConnection, errorMessage: "接收失败：\(error.localizedDescription)")
                    return
                }

                if isComplete {
                    if p2pConnection.frameAssembler.hasPartialFrame {
                        self.terminate(p2pConnection, errorMessage: "连接结束时仍有未完成帧")
                    } else {
                        self.terminate(p2pConnection, errorMessage: "连接已断开，已清空接收缓冲")
                    }
                    return
                }

                self.receiveData(on: p2pConnection)
            }
        }
    }

    // MARK: - Complete frame writes

    /// Sends one complete length-prefixed frame. The serial per-connection
    /// queue and the explicit chunk loop make it impossible to report success
    /// after only a prefix or a partial payload was accepted.
    @discardableResult
    func send(_ data: Data,
              to friendID: UUID,
              completion: ((Bool) -> Void)? = nil) -> Bool {
        let frame: Data
        do {
            frame = try P2PFrameCodec.encode(data)
        } catch {
            print("P2P frame encode error: \(error)")
            completion?(false)
            return false
        }

        guard let p2pConnection = connections[friendID] else {
            completion?(false)
            return false
        }

        queue.async { [weak self, weak p2pConnection] in
            guard let self = self,
                  let p2pConnection = p2pConnection,
                  connections[p2pConnection.id] === p2pConnection,
                  !p2pConnection.isTerminated else {
                completion?(false)
                return
            }
            p2pConnection.pendingSendData.append(frame)
            if let completion = completion {
                p2pConnection.sendCompletions.append(completion)
            }
            self.pumpSendQueue(p2pConnection)
        }
        return true
    }

    private func pumpSendQueue(_ p2pConnection: P2PConnection) {
        guard !p2pConnection.isTerminated,
              !p2pConnection.sendInFlight else { return }

        if p2pConnection.activeSendData == nil {
            guard !p2pConnection.pendingSendData.isEmpty else {
                let completions = p2pConnection.sendCompletions
                p2pConnection.sendCompletions.removeAll()
                for completion in completions { completion(true) }
                return
            }
            p2pConnection.activeSendData = p2pConnection.pendingSendData
            p2pConnection.pendingSendData.removeAll(keepingCapacity: true)
            p2pConnection.activeSendOffset = 0
        }

        guard let activeData = p2pConnection.activeSendData else { return }
        let start = p2pConnection.activeSendOffset
        let end = min(activeData.count, start + maximumSendChunk)
        let chunk = Data(activeData[start..<end])
        p2pConnection.sendInFlight = true

        p2pConnection.connection.send(content: chunk, completion: .contentProcessed { [weak self, weak p2pConnection] error in
            guard let self = self, let p2pConnection = p2pConnection else { return }
            self.queue.async {
                guard !p2pConnection.isTerminated else { return }
                p2pConnection.sendInFlight = false

                if let error = error {
                    self.terminate(p2pConnection, errorMessage: "发送失败：\(error.localizedDescription)")
                    return
                }

                p2pConnection.activeSendOffset = end
                if end < activeData.count {
                    self.pumpSendQueue(p2pConnection)
                } else {
                    p2pConnection.activeSendData = nil
                    p2pConnection.activeSendOffset = 0
                    self.pumpSendQueue(p2pConnection)
                }
            }
        })
    }

    // MARK: - Teardown

    private func terminate(_ p2pConnection: P2PConnection, errorMessage: String) {
        guard !p2pConnection.isTerminated else { return }
        p2pConnection.isTerminated = true
        p2pConnection.frameAssembler.reset()
        p2pConnection.pendingSendData.removeAll(keepingCapacity: false)
        p2pConnection.activeSendData = nil
        p2pConnection.activeSendOffset = 0
        p2pConnection.sendInFlight = false

        let completions = p2pConnection.sendCompletions
        p2pConnection.sendCompletions.removeAll()
        for completion in completions { completion(false) }

        if connections[p2pConnection.id] === p2pConnection {
            connections.removeValue(forKey: p2pConnection.id)
        }
        p2pConnection.connection.cancel()

        if !p2pConnection.userInitiatedClose || errorMessage.contains("帧") {
            DispatchQueue.main.async { [weak self] in
                self?.onConnectionError?(p2pConnection.id, errorMessage)
            }
        } else {
            print("[P2P] \(errorMessage)")
        }
    }

    func disconnect(friendID: UUID) {
        let p2pConnection = connections[friendID]
        connections.removeValue(forKey: friendID)
        guard let p2pConnection = p2pConnection else { return }
        p2pConnection.userInitiatedClose = true
        queue.async { [weak self] in
            self?.terminate(p2pConnection, errorMessage: "连接已断开，已清空接收缓冲")
        }
    }

    func disconnectAll() {
        let currentConnections = Array(connections.values)
        connections.removeAll()
        for p2pConnection in currentConnections {
            p2pConnection.userInitiatedClose = true
        }
        queue.async { [weak self] in
            for p2pConnection in currentConnections {
                self?.terminate(p2pConnection, errorMessage: "连接已断开，已清空接收缓冲")
            }
        }
    }
}
