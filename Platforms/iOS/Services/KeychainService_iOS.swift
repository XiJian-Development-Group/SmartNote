import Foundation
import Security

/// iOS Keychain 实现。满足 `KeychainStoring` 协议，给 `StorageService` 注入使用。
final class KeychainService_iOS: KeychainStoring {
    enum KeychainError: Error, LocalizedError {
        case unhandledError(status: OSStatus)
        case dataConversion
        case invalidAccount
        case invalidService

        var errorDescription: String? {
            switch self {
            case .unhandledError(let status):
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

    init(service: String = "com.skyc8266.smartnote.ios") {
        self.service = service
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account {
            query[kSecAttrAccount as String] = account
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

        // 先查询是否存在，再更新或新增
        var lookupQuery = baseQuery
        lookupQuery[kSecReturnData as String] = false
        lookupQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let readStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
        switch readStatus {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                lookupQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: updateStatus)
            }
            return true
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            // iOS 专用：防止备份到 iCloud
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledError(status: addStatus)
            }
            return true
        default:
            throw KeychainError.unhandledError(status: readStatus)
        }
    }

    func readString(for account: String) throws -> String? {
        guard !service.isEmpty else { throw KeychainError.invalidService }
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledError(status: status) }

        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataConversion
        }
        return string
    }

    @discardableResult
    func deleteString(for account: String) -> Bool {
        guard !service.isEmpty, !account.isEmpty else { return false }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func listAccounts() -> [String] {
        guard !service.isEmpty else { return [] }
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func deleteAll() {
        guard !service.isEmpty else { return }
        let status = SecItemDelete(baseQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] 清理 service 失败 (status=\(status))")
        }
    }
}