import Foundation
import CryptoKit
import CommonCrypto

class DiaryEncryptionService {
    static let shared = DiaryEncryptionService()
    
    private let keychainService = "com.smartnote.diary"
    
    private init() {}
    
    func encryptDiary(_ entry: DiaryEntry, password: String) -> DiaryEntry {
        guard let encryptedContent = encrypt(entry.content, password: password) else {
            return entry
        }
        
        var encryptedEntry = entry
        encryptedEntry.content = encryptedContent
        encryptedEntry.isEncrypted = true
        return encryptedEntry
    }
    
    func decryptDiary(_ entry: DiaryEntry, password: String) -> DiaryEntry? {
        guard entry.isEncrypted else { return entry }
        
        guard let decryptedContent = decrypt(entry.content, password: password) else {
            return nil
        }
        
        var decryptedEntry = entry
        decryptedEntry.content = decryptedContent
        decryptedEntry.isEncrypted = false
        return decryptedEntry
    }
    
    func verifyPassword(_ password: String) -> Bool {
        let settings = loadEncryptionSettings()
        return settings.password == password
    }
    
    func saveEncryptionSettings(_ settings: DiaryEncryptionSettings) {
        let data = try? JSONEncoder().encode(settings)
        UserDefaults.standard.set(data, forKey: "diaryEncryptionSettings")
        
        if !settings.password.isEmpty {
            saveToKeychain(settings.password, key: "diaryPassword")
        }
    }
    
    func loadEncryptionSettings() -> DiaryEncryptionSettings {
        guard let data = UserDefaults.standard.data(forKey: "diaryEncryptionSettings"),
              let settings = try? JSONDecoder().decode(DiaryEncryptionSettings.self, from: data) else {
            return DiaryEncryptionSettings()
        }
        return settings
    }
    
    func isEncryptionEnabled() -> Bool {
        return loadEncryptionSettings().isEnabled
    }
    
    func verifySecurityAnswer(_ answer: String) -> Bool {
        let settings = loadEncryptionSettings()
        return settings.securityAnswer.lowercased() == answer.lowercased()
    }
    
    private func encrypt(_ text: String, password: String) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        
        let salt = SymmetricKey(size: .bits256)
        let key = deriveKey(from: password, salt: salt)
        
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            guard let combined = sealedBox.combined else { return nil }
            return combined.base64EncodedString()
        } catch {
            return nil
        }
    }
    
    private func decrypt(_ encryptedText: String, password: String) -> String? {
        guard let data = Data(base64Encoded: encryptedText) else { return nil }
        
        let salt = SymmetricKey(size: .bits256)
        let key = deriveKey(from: password, salt: salt)
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return String(data: decryptedData, encoding: .utf8)
        } catch {
            return nil
        }
    }
    
    private func deriveKey(from password: String, salt: SymmetricKey) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let saltData = withUnsafeBytes(of: salt) { Data($0) }
        
        var keyData = Data(count: 32)
        
        keyData.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                saltData.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        10000,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        
        return SymmetricKey(data: keyData)
    }
    
    private func saveToKeychain(_ value: String, key: String) {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
        
        var newQuery = query
        newQuery[kSecValueData as String] = data
        
        SecItemAdd(newQuery as CFDictionary, nil)
    }
}
