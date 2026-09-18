import Foundation
import Security

/// macOS Keychain 封装。系统原生（`Security` framework），不引第三方依赖。
///
/// - 角色：把用户用于文件加密的"密码"以 `kSecClassGenericPassword` 形式存进
///   用户登录钥匙串（login keychain），按文件名维度存/取/删/列。
/// - 安全模型：
///     • 服务标识 `com.skyc8266.smartnote.file-crypto`
///     • 账号 = 文件名（含相对路径也可，用规范化路径）
///     • 仅存加密文件的密码；明文数据文件本身不进钥匙串
///     • 跨设备同步不会自动发生（默认 `kSecAttrSynchronizable` 为 false）
final class KeychainService {

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case dataConversion

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s):
                return "Keychain 错误 (status=\(s))"
            case .dataConversion:
                return "Keychain 数据转换失败"
            }
        }
    }

    /// 服务标识，限定本 app 范围，避免与其他 app 冲突
    private let service: String

    init(service: String = "com.skyc8266.smartnote.file-crypto") {
        self.service = service
    }

    // MARK: - 增 / 查 / 改 / 删

    /// 保存密码（覆盖式：已存在同 account 则更新）
    func savePassword(_ password: String, for account: String) throws {
        guard let data = password.data(using: .utf8) else {
            throw KeychainError.dataConversion
        }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 先查询是否已存在
        let readQuery = baseQuery
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, nil)
        switch readStatus {
        case errSecSuccess:
            // 更新
            let attrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        case errSecItemNotFound:
            // 新增
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(readStatus)
        }
    }

    /// 取密码（若不存在返回 nil，不抛错）
    func loadPassword(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let pwd = String(data: data, encoding: .utf8) else {
            return nil
        }
        return pwd
    }

    /// 删除指定密码（不存在则 no-op，不抛错）
    @discardableResult
    func deletePassword(for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 列出所有已存密码的"账号"（仅我们 service 范围）
    /// - Note: Keychain 的 SecItemCopyMatching 不直接列 attribute；
    ///         这里用 `kSecMatchLimitAll` + `kSecReturnAttributes` 走一遍
    func listAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// 删除该 service 下所有条目（一次性清理）
    func deleteAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
