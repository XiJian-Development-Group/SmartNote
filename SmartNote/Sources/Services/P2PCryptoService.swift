import Foundation
import Security
import CommonCrypto
import CryptoKit

class P2PCryptoService {
    static let shared = P2PCryptoService()
    
    private init() {}
    
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
        let fingerprint = generateFingerprint(publicKeyData)
        
        let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? ?? Data()
        
        savePrivateKey(privateKeyData, identifier: privateKeyID)
        
        return (publicKeyBase64, privateKeyID, fingerprint)
    }
    
    private func generateFingerprint(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
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
    
    func generateAESKey() -> Data {
        var keyData = Data(count: 32)
        _ = keyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 32, bytes.baseAddress!)
        }
        return keyData
    }
    
    func aesEncrypt(_ data: Data, key: Data) -> Data? {
        guard data.count > 0, key.count == 32 else { return nil }
        
        var iv = Data(count: 12)
        _ = iv.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 12, bytes.baseAddress!)
        }
        
        var encryptedData = Data()
        encryptedData.append(iv)
        
        var numBytesEncrypted: size_t = 0
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        
        let status = buffer.withUnsafeMutableBytes { bytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            bytes.baseAddress, bufferSize,
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
    
    func aesDecrypt(_ data: Data, key: Data) -> Data? {
        guard data.count > 12, key.count == 32 else { return nil }
        
        let iv = data.prefix(12)
        let encryptedData = data.suffix(from: 12)
        
        var decryptedData = Data()
        var numBytesDecrypted: size_t = 0
        let bufferSize = encryptedData.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        
        let status = buffer.withUnsafeMutableBytes { bytes in
            encryptedData.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, encryptedData.count,
                            bytes.baseAddress, bufferSize,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }
        
        guard status == kCCSuccess else { return nil }
        
        decryptedData.append(buffer.prefix(numBytesDecrypted))
        return decryptedData
    }
    
    func deletePrivateKey(identifier: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "P2PPrivateKey_\(identifier)"
        ]
        SecItemDelete(query as CFDictionary)
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
              let data = item as? Data else { return nil }
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
