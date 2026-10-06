import Foundation
import Security

/// macOS Keychain 封装。系统原生（`Security` framework），不引第三方依赖。
///
/// - 存储格式：值统一以 UTF-8 `Data` 写入 `kSecClassGenericPassword`，读取时再转回 `String`。
/// - 服务范围：`service` 下的所有条目；默认 service 同时承载文件加密密码和 LLM API key。
/// - 清理口径：`deleteAll()` 会删除该 service 下的全部条目，因此 SmartNote 的“清除所有数据”
///   仍会一并清除 API key。
/// - 安全模型：默认使用用户登录钥匙串，条目在用户解锁后可访问，且不启用 iCloud 同步。
final class KeychainService {

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

    /// 服务标识，限定本 app 范围，避免与其他 app 冲突。
    private let service: String
    /// 默认 nil 表示使用用户登录钥匙串；测试/隔离运行可注入临时 keychain。
    private let keychain: SecKeychain?

    init(
        service: String = "com.skyc8266.smartnote.file-crypto",
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

    /// 读取/更新/删除指定 keychain 时使用 search list；SecItem 在自定义 keychain
    /// 上的读取不能只依赖 kSecUseKeychain。
    private func lookupQuery(account: String? = nil) -> [String: Any] {
        var query = baseQuery(account: account)
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    // MARK: - 通用字符串条目

    /// 保存或覆盖一个 UTF-8 字符串条目。失败会抛出 `KeychainError`，不会崩溃。
    @discardableResult
    func setString(_ value: String, for account: String) throws -> Bool {
        guard !service.isEmpty else { throw KeychainError.invalidService }
        guard !account.isEmpty else { throw KeychainError.invalidAccount }
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataConversion
        }

        let baseQuery = baseQuery(account: account)

        // 先查询是否存在，再更新或新增。某些 macOS securityd 版本对直接
        // SecItemUpdate 一个不存在的条目会阻塞，因此保留旧实现的安全查询路径。
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

    /// 读取字符串条目。`nil` 仅表示条目不存在；其它 Keychain 错误会抛出。
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

    /// 删除字符串条目。不存在视为成功；其它错误返回 `false`，不抛出、不崩溃。
    @discardableResult
    func deleteString(for account: String) -> Bool {
        guard !service.isEmpty, !account.isEmpty else { return false }
        let status = SecItemDelete(lookupQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - 语义化别名

    @discardableResult
    func set(_ value: String, for account: String) throws -> Bool {
        try setString(value, for: account)
    }

    func read(for account: String) throws -> String? {
        try readString(for: account)
    }

    @discardableResult
    func delete(for account: String) -> Bool {
        deleteString(for: account)
    }

    // MARK: - 兼容现有文件加密调用

    /// 保存密码（覆盖式：已存在同 account 则更新）。
    func savePassword(_ password: String, for account: String) throws {
        try setString(password, for: account)
    }

    /// 取密码（不存在或读取失败返回 nil，保持旧调用方的非崩溃行为）。
    func loadPassword(for account: String) -> String? {
        (try? readString(for: account)) ?? nil
    }

    /// 删除指定密码（不存在则 no-op）。
    @discardableResult
    func deletePassword(for account: String) -> Bool {
        deleteString(for: account)
    }

    /// 列出所有已存条目的 account（仅当前 service 范围）。
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

    /// 删除该 service 下所有条目（一次性清理，包含 LLM API key）。
    func deleteAll() {
        guard !service.isEmpty else { return }
        let status = SecItemDelete(lookupQuery() as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("[Keychain] 清理 service 失败 (status=\(status))")
        }
    }
}
