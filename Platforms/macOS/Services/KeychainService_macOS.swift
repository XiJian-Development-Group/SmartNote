import Foundation
import Security

/// macOS Keychain 实现。满足 `KeychainStoring` 协议，给 `StorageService` 注入使用。
final class KeychainService_macOS: KeychainStoring {
    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversion
        case invalidAccount
        case invalidService

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain 错误 (status=\(status))"
            case .dataConversion:
                return "Keychain 数据转换失败"
            case .invalidAccount:
                return "Keychain account 不能为空"
            case .invalidService:
                return "Keychain service 不能为空"
            }
        }
    }

    private let service: String
    private let keychain: SecKeychain?

    init(
        service: String = "com.skyc8266.smartnote",
        keychain: SecKeychain? = nil
    ) {
        self.service = service
        self.keychain = keychain
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let keychain {
            query[kSecUseKeychain as String] = keychain
        }
        return query
    }

    private func lookupQuery(account: String? = nil) -> [String: Any] {
        var query = baseQuery(account: account)
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    @discardableResult
    func setString(_ value: String, for account: String) throws -> Bool {
        guard !service.isEmpty else { throw KeychainError.invalidService }
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataConversion
        }

        let baseQuery = baseQuery(account: account)
        let lookupQuery = lookupQuery(account: account)
        let readStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
        switch readStatus {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                lookupQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
            return true
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return true
        default:
            throw KeychainError.unexpectedStatus(readStatus)
        }
    }

    func readString(for account: String) throws -> String? {
        guard !service.isEmpty else { throw KeychainError.invalidService }
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        var query = lookupQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.dataConversion
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    @discardableResult
    func deleteString(for account: String) -> Bool {
        guard !service.isEmpty, !account.isEmpty else { return false }
        let status = SecItemDelete(lookupQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func listAccounts() -> [String] {
        guard !service.isEmpty else { return [] }
        var query = lookupQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func deleteAll() {
        guard !service.isEmpty else { return }
        let status = SecItemDelete(lookupQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] 清理 service 失败 (status=\(status))")
        }
    }
}