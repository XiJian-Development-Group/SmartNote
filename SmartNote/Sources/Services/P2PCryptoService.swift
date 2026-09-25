import Foundation
import Security
import CommonCrypto
import CryptoKit

/// P2P 会话密钥的版本化载体。
///
/// 线上的握手仍然可以携带旧版本的裸 32 字节密钥，但新代码始终把密钥当作
/// `P2PKeyMaterial` 处理。这样将来轮换密钥时，可以拒绝未知版本，而不是悄悄
/// 把未知字节当成同一种密钥使用。
struct P2PKeyMaterial: Equatable {
    static let currentVersion: UInt8 = 1
    static let legacyCBCVersion: UInt8 = 0
    static let keyByteCount = 32

    let version: UInt8
    let rawKey: Data

    init(rawKey: Data, version: UInt8 = P2PKeyMaterial.currentVersion) throws {
        guard rawKey.count == P2PKeyMaterial.keyByteCount else {
            throw P2PKeyMaterialError.invalidKeyLength
        }
        guard version == P2PKeyMaterial.legacyCBCVersion || version == P2PKeyMaterial.currentVersion else {
            throw P2PKeyMaterialError.unsupportedVersion(version)
        }
        self.version = version
        self.rawKey = rawKey
    }

    var symmetricKey: SymmetricKey {
        SymmetricKey(data: rawKey)
    }

    /// 仅用于调试/协议测试；实际握手由 RSA 加密这个 raw key，再在 ack 中带版本。
    func encoded() -> Data {
        Data([version]) + rawKey
    }

    static func decode(_ data: Data) throws -> P2PKeyMaterial {
        guard let version = data.first else {
            throw P2PKeyMaterialError.invalidEncoding
        }
        return try P2PKeyMaterial(rawKey: Data(data.dropFirst()), version: version)
    }
}

enum P2PPeerTrustDecision: Equatable {
    case trusted
    case needsConfirmation
    case mismatch
}

/// Pure identity policy used by the handshake and by standalone probes. The
/// persisted friend record is the trust anchor; an unknown key is never treated
/// as trusted until the user explicitly confirms it.
enum P2PPeerTrustPolicy {
    static func evaluate(
        peerID: UUID,
        presentedPublicKey: String,
        presentedFingerprint: String,
        recordedPublicKeys: [UUID: String],
        fingerprintForKey: (String) -> String
    ) -> P2PPeerTrustDecision {
        guard let recordedPublicKey = recordedPublicKeys[peerID],
              !recordedPublicKey.isEmpty else {
            return .needsConfirmation
        }
        let recordedFingerprint = fingerprintForKey(recordedPublicKey)
        guard recordedFingerprint != "无效公钥",
              recordedPublicKey == presentedPublicKey,
              recordedFingerprint == presentedFingerprint else {
            return .mismatch
        }
        return .trusted
    }
}

enum P2PKeyMaterialError: Error, Equatable, LocalizedError {
    case invalidKeyLength
    case unsupportedVersion(UInt8)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .invalidKeyLength:
            return "会话密钥长度无效"
        case .unsupportedVersion(let version):
            return "不支持的会话密钥版本：\(version)"
        case .invalidEncoding:
            return "会话密钥编码无效"
        }
    }
}

/// 应用层消息的信封格式。
///
/// 新消息使用 `magic + version + AES-GCM combined`，其中 combined 包含
/// 96-bit 随机 nonce、密文和 128-bit 认证标签。没有 magic 的旧数据按 CBC
/// 读取；CBC 只用于兼容历史消息，不提供认证完整性。
enum P2PMessageCipherVersion: UInt8 {
    case legacyCBC = 0
    case aesGCM = 1
}

enum P2PMessageEnvelope {
    // A four-byte marker makes accidental classification of a random legacy
    // CBC IV as GCM vanishingly unlikely; the version remains a separate byte.
    static let magic = Data([0x50, 0x32, 0x47, 0x31]) // ASCII "P2G1"
    static let version = P2PMessageCipherVersion.aesGCM.rawValue
    static let nonceByteCount = 12
    static let tagByteCount = 16
    static let headerByteCount = 5

    static func isGCMEnvelope(_ data: Data) -> Bool {
        data.count >= headerByteCount && data.prefix(magic.count) == magic && data[magic.count] == version
    }

    static func nonce(in data: Data) -> Data? {
        guard isGCMEnvelope(data),
              data.count >= headerByteCount + nonceByteCount else { return nil }
        let start = data.index(data.startIndex, offsetBy: headerByteCount)
        let end = data.index(start, offsetBy: nonceByteCount)
        return Data(data[start..<end])
    }

    static func authenticationTag(in data: Data) -> Data? {
        guard isGCMEnvelope(data), data.count >= tagByteCount else { return nil }
        return Data(data.suffix(tagByteCount))
    }
}

enum P2PDecryptionError: Error, Equatable, LocalizedError {
    case invalidKey
    case malformedMessage
    case unsupportedVersion(UInt8)
    case authenticationFailed
    case legacyCBCFailed
    case invalidUTF8

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "会话密钥无效"
        case .malformedMessage:
            return "加密消息格式无效"
        case .unsupportedVersion(let version):
            return "不支持的消息加密版本：\(version)"
        case .authenticationFailed:
            return "AES-GCM 认证失败（密文、认证标签或密钥错误）"
        case .legacyCBCFailed:
            return "旧 AES-CBC 消息解密失败"
        case .invalidUTF8:
            return "解密结果不是有效 UTF-8 文本"
        }
    }
}

final class P2PCryptoService {
    static let shared = P2PCryptoService()

    private init() {}

    // MARK: - RSA identity and fingerprints

    func generateRSAKeyPair() -> (publicKey: String, privateKeyRef: String, fingerprint: String)? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            print("Error generating private key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            print("Error getting public key")
            return nil
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("Error exporting public key")
            return nil
        }

        let publicKeyBase64 = publicKeyData.base64EncodedString()
        let privateKeyID = UUID().uuidString
        let fingerprint = fingerprint(forPublicKeyData: publicKeyData)
        let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? ?? Data()

        savePrivateKey(privateKeyData, identifier: privateKeyID)

        return (publicKeyBase64, privateKeyID, fingerprint)
    }

    /// 返回完整 SHA-256 指纹，而不是只截取几个字节，便于用户核对身份。
    func fingerprint(forPublicKey publicKeyString: String) -> String {
        guard let data = Data(base64Encoded: publicKeyString),
              isValidPublicKeyData(data) else {
            return "无效公钥"
        }
        return fingerprint(forPublicKeyData: data)
    }

    func isValidPublicKey(_ publicKeyString: String) -> Bool {
        guard let data = Data(base64Encoded: publicKeyString) else { return false }
        return isValidPublicKeyData(data)
    }

    private func isValidPublicKeyData(_ data: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        guard let publicKey = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, nil) else {
            return false
        }
        // Do not trust an accidentally accepted RSA-512/1024 identity.
        return SecKeyGetBlockSize(publicKey) == 256
    }

    private func fingerprint(forPublicKeyData data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private func savePrivateKey(_ keyData: Data, identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "P2PPrivateKey_\(identifier)",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadPrivateKey(identifier: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "P2PPrivateKey_\(identifier)",
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let keyData = item as? Data else {
            return nil
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]

        return SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil)
    }

    func encryptWithPublicKey(_ data: Data, publicKeyString: String) -> Data? {
        guard let publicKeyData = Data(base64Encoded: publicKeyString) else { return nil }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]

        guard let publicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, nil) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let encryptedData = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionOAEPSHA256,
            data as CFData,
            &error
        ) as Data? else {
            return nil
        }

        return encryptedData
    }

    func decryptWithPrivateKey(_ data: Data, privateKeyRef: String) -> Data? {
        guard let privateKey = loadPrivateKey(identifier: privateKeyRef) else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let decryptedData = SecKeyCreateDecryptedData(
            privateKey,
            .rsaEncryptionOAEPSHA256,
            data as CFData,
            &error
        ) as Data? else {
            return nil
        }

        return decryptedData
    }

    func deletePrivateKey(identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "P2PPrivateKey_\(identifier)"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Versioned application-layer message encryption

    func generateAESKey() -> Data {
        let keyByteCount = P2PKeyMaterial.keyByteCount
        var keyData = Data(count: keyByteCount)
        let status = keyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, keyByteCount, bytes.baseAddress!)
        }
        if status != errSecSuccess {
            // Never substitute a predictable key if the system RNG fails. The
            // versioned key initializer will reject this and abort the handshake.
            return Data()
        }
        return keyData
    }

    /// 新消息使用 AES-GCM。每次 seal 都由 CryptoKit 生成新的随机 96-bit nonce；
    /// nonce 与密文、认证标签一起放进返回的信封，不复用 nonce。
    func encryptMessage(_ data: Data, using keyMaterial: P2PKeyMaterial) throws -> Data {
        guard keyMaterial.rawKey.count == P2PKeyMaterial.keyByteCount else {
            throw P2PDecryptionError.invalidKey
        }

        do {
            let nonce = AES.GCM.Nonce()
            let sealedBox = try AES.GCM.seal(
                data,
                using: keyMaterial.symmetricKey,
                nonce: nonce
            )
            guard let combined = sealedBox.combined else {
                throw P2PDecryptionError.malformedMessage
            }
            var envelope = P2PMessageEnvelope.magic
            envelope.append(P2PMessageEnvelope.version)
            envelope.append(combined)
            return envelope
        } catch let error as P2PDecryptionError {
            throw error
        } catch {
            print("[Crypto] AES-GCM seal failed: \(error)")
            throw P2PDecryptionError.malformedMessage
        }
    }

    func decryptMessage(_ data: Data, using keyMaterial: P2PKeyMaterial) throws -> Data {
        guard keyMaterial.rawKey.count == P2PKeyMaterial.keyByteCount else {
            throw P2PDecryptionError.invalidKey
        }

        let isLegacyKey = keyMaterial.version == P2PKeyMaterial.legacyCBCVersion
        if P2PMessageEnvelope.isGCMEnvelope(data) {
            guard data.count >= P2PMessageEnvelope.headerByteCount + P2PMessageEnvelope.nonceByteCount + P2PMessageEnvelope.tagByteCount else {
                if isLegacyKey { return try decryptLegacyCBC(data, key: keyMaterial.rawKey) }
                throw P2PDecryptionError.malformedMessage
            }

            do {
                let combined = Data(data.dropFirst(P2PMessageEnvelope.headerByteCount))
                let sealedBox = try AES.GCM.SealedBox(combined: combined)
                return try AES.GCM.open(sealedBox, using: keyMaterial.symmetricKey)
            } catch {
                // A legacy IV can coincidentally begin with the marker; give
                // version-0 sessions one compatibility attempt, while current
                // sessions never downgrade on a GCM authentication failure.
                if isLegacyKey { return try decryptLegacyCBC(data, key: keyMaterial.rawKey) }
                // 不把 CryptoKit 的错误或任何候选明文返回给上层。
                throw P2PDecryptionError.authenticationFailed
            }
        }

        // A current-version session must never silently fall back to CBC when
        // an attacker removes or corrupts the GCM marker. Legacy CBC is only
        // eligible for a key explicitly negotiated as version 0. For a legacy
        // key, a random IV that happens to begin with the marker is still
        // treated as CBC so old data remains readable.
        if keyMaterial.version == P2PKeyMaterial.currentVersion {
            if data.count >= P2PMessageEnvelope.magic.count,
               data.prefix(P2PMessageEnvelope.magic.count) == P2PMessageEnvelope.magic {
                guard let version = data.dropFirst(P2PMessageEnvelope.magic.count).first else {
                    throw P2PDecryptionError.malformedMessage
                }
                throw P2PDecryptionError.unsupportedVersion(version)
            }
            throw P2PDecryptionError.authenticationFailed
        }

        return try decryptLegacyCBC(data, key: keyMaterial.rawKey)
    }

    /// 兼容旧 API：现在返回带版本的 GCM 信封，而不是 CBC。
    func aesEncrypt(_ data: Data, key: Data) -> Data? {
        guard let keyMaterial = try? P2PKeyMaterial(rawKey: key) else { return nil }
        return try? encryptMessage(data, using: keyMaterial)
    }

    /// 兼容旧 API：优先读取 GCM；无 GCM 标记时再用版本 0 的 CBC 读取器
    /// 尝试历史数据。新的握手/消息路径使用 `decryptMessage` 的严格版本门控，
    /// 不会因为标记被篡改而降级到 CBC。
    func aesDecrypt(_ data: Data, key: Data) -> Data? {
        guard let currentKey = try? P2PKeyMaterial(rawKey: key, version: P2PKeyMaterial.currentVersion) else {
            return nil
        }
        if let plaintext = try? decryptMessage(data, using: currentKey) {
            return plaintext
        }
        guard let legacyKey = try? P2PKeyMaterial(rawKey: key, version: P2PKeyMaterial.legacyCBCVersion) else {
            return nil
        }
        return try? decryptMessage(data, using: legacyKey)
    }

    /// 仅为读取历史 CBC 消息保留；新发送路径不会调用它。
    func encryptLegacyCBCForCompatibility(_ data: Data, key: Data) -> Data? {
        legacyCBCEncrypt(data, key: key)
    }

    /// 仅为读取历史 CBC 消息保留；CBC 没有认证标签，不能检测所有篡改。
    func decryptLegacyCBCForCompatibility(_ data: Data, key: Data) -> Data? {
        try? decryptLegacyCBC(data, key: key)
    }

    func isLegacyCBCMessage(_ data: Data) -> Bool {
        !P2PMessageEnvelope.isGCMEnvelope(data)
    }

    private func decryptLegacyCBC(_ data: Data, key: Data) throws -> Data {
        guard key.count == P2PKeyMaterial.keyByteCount else {
            throw P2PDecryptionError.invalidKey
        }

        // The previous implementation prefixed a 12-byte IV even though
        // CommonCrypto consumes a 16-byte AES IV. Read that historical layout
        // by zero-extending its IV, and also accept a proper 16-byte-IV CBC
        // blob for compatibility probes/future migration tools.
        let ivLength: Int
        switch data.count % kCCBlockSizeAES128 {
        case 12: ivLength = 12 // legacy 12-byte-prefix layout
        case 0: ivLength = kCCBlockSizeAES128
        default:
            throw P2PDecryptionError.malformedMessage
        }
        guard data.count > ivLength else {
            throw P2PDecryptionError.malformedMessage
        }

        let legacyIV = Data(data.prefix(ivLength))
        let iv = ivLength == 12
            ? legacyIV + Data(repeating: 0, count: kCCBlockSizeAES128 - 12)
            : legacyIV
        let encryptedData = Data(data.dropFirst(ivLength))
        guard !encryptedData.isEmpty, encryptedData.count % kCCBlockSizeAES128 == 0 else {
            throw P2PDecryptionError.malformedMessage
        }

        var decryptedData = Data()
        var numBytesDecrypted: size_t = 0
        let encryptedByteCount = encryptedData.count
        let keyByteCount = key.count
        let bufferSize = encryptedByteCount + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)

        let status = buffer.withUnsafeMutableBytes { outputBytes in
            encryptedData.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyByteCount,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, encryptedByteCount,
                            outputBytes.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw P2PDecryptionError.legacyCBCFailed
        }
        decryptedData.append(buffer.prefix(numBytesDecrypted))
        return decryptedData
    }

    private func legacyCBCEncrypt(_ data: Data, key: Data) -> Data? {
        guard !data.isEmpty, key.count == P2PKeyMaterial.keyByteCount else { return nil }

        let ivByteCount = kCCBlockSizeAES128
        var iv = Data(count: ivByteCount)
        let randomStatus = iv.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, ivByteCount, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { return nil }

        var encryptedData = iv
        var numBytesEncrypted: size_t = 0
        let plaintextByteCount = data.count
        let keyByteCount = key.count
        let bufferSize = plaintextByteCount + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)

        let status = buffer.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, keyByteCount,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress, plaintextByteCount,
                            outputBytes.baseAddress, bufferSize,
                            &numBytesEncrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        encryptedData.append(buffer.prefix(numBytesEncrypted))
        return encryptedData
    }

    // MARK: - Local Storage Encryption

    private let localStorageKeychainAccount = "P2PLocalStorageKey"

    func getOrCreateLocalStorageKey() -> SymmetricKey {
        if let existing = loadLocalStorageKey() { return existing }
        let newKey = SymmetricKey(size: .bits256)
        saveLocalStorageKey(newKey)
        return newKey
    }

    private func loadLocalStorageKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: localStorageKeychainAccount,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    private func saveLocalStorageKey(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: localStorageKeychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteLocalStorageKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: localStorageKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    func encryptLocalData(_ data: Data) -> Data? {
        let key = getOrCreateLocalStorageKey()
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            return sealedBox.combined
        } catch {
            print("[Crypto] Local encrypt failed: \(error)")
            return nil
        }
    }

    func decryptLocalData(_ data: Data) -> Data? {
        let key = getOrCreateLocalStorageKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            print("[Crypto] Local decrypt failed: \(error)")
            return nil
        }
    }
}
