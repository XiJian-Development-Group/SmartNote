import Foundation
import CryptoKit
import CommonCrypto
import Security

/// 日记正文加密/解密服务。
///
/// 安全边界（请同步到用户文档）：这是**本地** AES-GCM 加密，不是端到端加密。
/// 启用加密时，`DiaryEntry` 的正文 `content` 会加密，但标题、分类、日期、置顶状态、关联资料、
/// 图片路径等元数据仍会以明文写入日记数据文件；图片文件本身也不在这段正文的
/// 加密范围内。备份/导出是否安全取决于它们各自的存储方式。
///
/// 当前格式（v2）：
/// `SND2:` + Base64(`"SND2"` + version + PBKDF2 iterations + 16-byte salt +
/// 12-byte nonce + AES-GCM ciphertext + 16-byte tag + 32-byte password verifier)。
/// AES-GCM 的 nonce 每次随机生成，并与密文一起保存；密钥使用
/// PBKDF2-HMAC-SHA256（当前 100,000 次、32-byte 输出）派生。password verifier
/// 使用独立的固定 salt，只用于把“密码错误”和“密文被篡改”区分开，不是额外的
/// 密钥，也不把密码写入 UserDefaults。
enum DiaryEncryptionError: Error, LocalizedError {
    case passwordEmpty
    case passwordTooShort(minimum: Int)
    case passwordsDoNotMatch
    case passwordNotConfigured
    case confirmationRequired
    case keychainMigrationFailed(String)
    case keyDerivationFailed(Int32)
    case encryptionFailed(String)
    case wrongPassword
    case corruptedData

    var errorDescription: String? {
        switch self {
        case .passwordEmpty:
            return "密码不能为空"
        case .passwordTooShort(let minimum):
            return "密码长度至少为 \(minimum) 个字符"
        case .passwordsDoNotMatch:
            return "两次输入的密码不一致"
        case .passwordNotConfigured:
            return "未配置日记加密密码"
        case .confirmationRequired:
            return "关闭加密需要二次确认"
        case .keychainMigrationFailed(let reason):
            return "钥匙串迁移失败：\(reason)"
        case .keyDerivationFailed(let status):
            return "密钥派生失败（status=\(status)）"
        case .encryptionFailed(let reason):
            return "加密失败：\(reason)"
        case .wrongPassword:
            return "解密失败：密码错误"
        case .corruptedData:
            return "解密失败：数据已损坏"
        }
    }
}

final class DiaryEncryptionService {
    static let shared = DiaryEncryptionService()

    /// 对外暴露版本号，方便迁移/探针确认格式，而不依赖模型增加字段。
    static let currentFormatVersion: UInt8 = 2
    static let currentFormatPrefix = "SND2:"
    static let minimumPasswordLength = 8

    static let passwordAccount = "diaryPassword"
    static let securityQuestionAccount = "diarySecurityQuestion"
    static let securityAnswerAccount = "diarySecurityAnswer"

    private static let settingsKey = "diaryEncryptionSettings"
    private static let settingsSchemaVersion = 1

    private static let currentMagic = Data([0x53, 0x4E, 0x44, 0x32]) // SND2
    private static let currentPBKDF2Iterations: UInt32 = 100_000
    private static let legacyPBKDF2Iterations: UInt32 = 10_000
    private static let currentSaltLength = 16
    private static let currentNonceLength = 12
    private static let currentTagLength = 16
    private static let passwordVerifierLength = 32
    private static let passwordVerifierIterations: UInt32 = 100_000
    private static let passwordVerifierSalt = Data([
        0x53, 0x4E, 0x44, 0x49, 0x41, 0x52, 0x59, 0x2D,
        0x50, 0x57, 0x2D, 0x56, 0x32, 0x21, 0x21, 0x21
    ]) // "SNDIARY-PW-V2!!!"
    private static let passwordVerifierMessage = Data("SmartNote diary password verifier v2".utf8)

    private let keychain: KeychainService
    private let userDefaults: UserDefaults
    private let migrationLock = NSLock()

    /// `keychainService` 和 `userDefaults` 可注入，便于独立迁移探针使用隔离的
    /// 钥匙串服务；应用本身使用上面的默认值。
    init(
        keychainService: KeychainService = KeychainService(service: "com.smartnote.diary"),
        userDefaults: UserDefaults = .standard
    ) {
        self.keychain = keychainService
        self.userDefaults = userDefaults

        // 服务首次创建时也尝试迁移，确保即使用户尚未打开日记编辑页，
        // 旧版明文设置也不会继续无期限留在 UserDefaults。
        do {
            try migrateLegacySettingsIfNeeded()
        } catch {
            print("[DiaryEncryption] 启动迁移失败，保留旧数据：\(error.localizedDescription)")
        }
    }

    // MARK: - 日记加解密

    /// 加密正文并返回新的 entry。失败时抛出错误，绝不返回原始明文 entry。
    func encryptDiary(_ entry: DiaryEntry, password: String) throws -> DiaryEntry {
        // 新写入统一执行密码下限校验；旧格式解密仍允许历史短密码读取。
        try validatePassword(password)

        let encryptedContent = try encrypt(entry.content, password: password)
        var encryptedEntry = entry
        encryptedEntry.content = encryptedContent
        encryptedEntry.isEncrypted = true
        return encryptedEntry
    }

    /// 解密正文并返回新的 entry。失败时抛出明确的错误，绝不返回空内容冒充成功。
    func decryptDiary(_ entry: DiaryEntry, password: String) throws -> DiaryEntry {
        guard entry.isEncrypted else { return entry }
        guard !password.isEmpty else { throw DiaryEncryptionError.wrongPassword }

        let decryptedContent = try decrypt(entry.content, password: password)
        var decryptedEntry = entry
        decryptedEntry.content = decryptedContent
        decryptedEntry.isEncrypted = false
        return decryptedEntry
    }

    /// 读取旧格式后立即写回当前格式的便捷入口。
    func reencryptDiary(_ entry: DiaryEntry, password: String) throws -> DiaryEntry {
        let plaintextEntry = try decryptDiary(entry, password: password)
        return try encryptDiary(plaintextEntry, password: password)
    }

    // MARK: - 设置与钥匙串迁移

    /// 启用加密时使用的服务层校验。UI 还必须提供“两次输入一致”和关闭确认。
    func enableEncryption(
        password: String,
        confirmation: String,
        securityQuestion: String = "",
        securityAnswer: String = ""
    ) throws {
        try validatePassword(password)
        guard password == confirmation else {
            throw DiaryEncryptionError.passwordsDoNotMatch
        }

        let settings = DiaryEncryptionSettings(
            isEnabled: true,
            password: password,
            securityQuestion: securityQuestion,
            securityAnswer: securityAnswer
        )
        try saveEncryptionSettingsChecked(settings)
    }

    /// 关闭加密的服务层入口。调用方必须先展示“将变为明文存储”的二次确认，
    /// 并把用户确认结果传进来；本方法不会隐式关闭。
    func disableEncryption(confirmed: Bool) throws {
        guard confirmed else { throw DiaryEncryptionError.confirmationRequired }

        var settings = loadEncryptionSettings()
        settings.isEnabled = false
        // 密码和答案继续留在钥匙串中，避免误触清除后无法重新启用；UserDefaults
        // 只更新 isEnabled，不写入任何敏感值。
        try saveEncryptionSettingsChecked(settings)
    }

    /// 保留旧调用方式的非抛出包装。真正的 UI 应使用 checked 版本并展示错误。
    func saveEncryptionSettings(_ settings: DiaryEncryptionSettings) {
        do {
            try saveEncryptionSettingsChecked(settings)
        } catch {
            print("[DiaryEncryption] 保存加密设置失败：\(error.localizedDescription)")
        }
    }

    /// 保存设置：密码、密保问题和答案只进入 Keychain；UserDefaults 只写非敏感开关。
    func saveEncryptionSettingsChecked(_ settings: DiaryEncryptionSettings) throws {
        if settings.isEnabled {
            let candidate = settings.password.isEmpty
                ? (keychain.loadPassword(for: Self.passwordAccount) ?? "")
                : settings.password
            try validatePassword(candidate)
        }

        // 先迁移旧明文设置。迁移失败时直接返回，避免用新值覆盖旧明文造成丢失。
        try migrateLegacySettingsIfNeeded()

        if !settings.password.isEmpty {
            try keychain.savePassword(settings.password, for: Self.passwordAccount)
        }
        if !settings.securityQuestion.isEmpty {
            try keychain.savePassword(settings.securityQuestion, for: Self.securityQuestionAccount)
        }
        if !settings.securityAnswer.isEmpty {
            try keychain.savePassword(settings.securityAnswer, for: Self.securityAnswerAccount)
        }

        let persisted = PersistedDiaryEncryptionSettings(
            schemaVersion: Self.settingsSchemaVersion,
            isEnabled: settings.isEnabled,
            hasSecurityQuestion: keychain.loadPassword(for: Self.securityQuestionAccount) != nil,
            hasSecurityAnswer: keychain.loadPassword(for: Self.securityAnswerAccount) != nil
        )
        try persistNonSensitiveSettings(persisted)
    }

    /// 从 UserDefaults 读取非敏感开关，并按需把旧版明文密码/答案迁移到钥匙串。
    /// 迁移失败时保留旧数据（不丢数据）并记录日志；密码/答案本身仍只从
    /// Keychain 提供，不会把 UserDefaults 中的旧明文当作可信运行时凭据。
    func loadEncryptionSettings() -> DiaryEncryptionSettings {
        let legacy = legacySettingsFromDefaults()

        do {
            try migrateLegacySettingsIfNeeded()
        } catch {
            print("[DiaryEncryption] 迁移旧 UserDefaults 设置失败，保留原数据：\(error.localizedDescription)")
        }

        let persisted = persistedSettingsFromDefaults()
        // 密码、问题和答案只从 Keychain 读取；迁移失败时宁可让加密保存失败，
        // 也不把仍留在磁盘上的旧明文重新作为运行时凭据。
        let password = keychain.loadPassword(for: Self.passwordAccount) ?? ""
        let question = keychain.loadPassword(for: Self.securityQuestionAccount) ?? ""
        let answer = keychain.loadPassword(for: Self.securityAnswerAccount) ?? ""

        return DiaryEncryptionSettings(
            isEnabled: persisted?.isEnabled ?? legacy?.isEnabled ?? false,
            password: password,
            securityQuestion: question,
            securityAnswer: answer
        )
    }

    func isEncryptionEnabled() -> Bool {
        loadEncryptionSettings().isEnabled
    }

    func hasSecurityAnswer() -> Bool {
        keychain.loadPassword(for: Self.securityAnswerAccount) != nil
    }

    /// 仅从 Keychain 验证密码；UserDefaults 不再参与验证。
    func verifyPassword(_ password: String) -> Bool {
        let stored = loadEncryptionSettings().password
        guard !stored.isEmpty, !password.isEmpty else { return false }
        return constantTimeEqual(stored, password)
    }

    /// 仅从 Keychain 验证密保答案；比较时忽略大小写。
    func verifySecurityAnswer(_ answer: String) -> Bool {
        let stored = loadEncryptionSettings().securityAnswer
        guard !stored.isEmpty, !answer.isEmpty else { return false }
        return constantTimeEqual(stored.lowercased(), answer.lowercased())
    }

    /// 加密开启但 Keychain 中没有密码时，调用方必须失败关闭，不能跳过加密。
    func passwordForEncryption() throws -> String {
        let password = loadEncryptionSettings().password
        guard !password.isEmpty else { throw DiaryEncryptionError.passwordNotConfigured }
        return password
    }

    /// 幂等迁移旧 `DiaryEncryptionSettings` JSON。
    ///
    /// 迁移顺序是：先把所有敏感值写入 Keychain，全部成功后才覆盖 UserDefaults
    /// 为只含布尔开关的 JSON。因此钥匙串失败时旧明文仍在（可重试），不会丢失；
    /// 成功后重复调用不会再次写入或改变结果。
    func migrateLegacySettingsIfNeeded() throws {
        migrationLock.lock()
        defer { migrationLock.unlock() }

        guard let raw = userDefaults.object(forKey: Self.settingsKey) else { return }
        guard let data = settingsData(from: raw) else {
            print("[DiaryEncryption] 旧 UserDefaults 设置无法读取，保留原数据")
            return
        }

        let decoder = JSONDecoder()
        if let persisted = try? decoder.decode(PersistedDiaryEncryptionSettings.self, from: data),
           persisted.schemaVersion == Self.settingsSchemaVersion,
           !jsonContainsSensitiveSettings(data) {
            return
        }

        guard let legacy = try? decoder.decode(LegacyDiaryEncryptionSettings.self, from: data) else {
            print("[DiaryEncryption] 旧 UserDefaults 设置格式无法识别，保留原数据")
            return
        }

        // 旧版本把问题文本也放在 JSON 中；一并放入钥匙串，UserDefaults 不保留它。
        if let question = legacy.securityQuestion, !question.isEmpty {
            try migrateSecret(question, account: Self.securityQuestionAccount)
        }
        if let password = legacy.password, !password.isEmpty {
            try migrateSecret(password, account: Self.passwordAccount)
        }
        if let answer = legacy.securityAnswer, !answer.isEmpty {
            try migrateSecret(answer, account: Self.securityAnswerAccount)
        }

        let sanitized = PersistedDiaryEncryptionSettings(
            schemaVersion: Self.settingsSchemaVersion,
            isEnabled: legacy.isEnabled ?? false,
            hasSecurityQuestion: keychain.loadPassword(for: Self.securityQuestionAccount) != nil,
            hasSecurityAnswer: keychain.loadPassword(for: Self.securityAnswerAccount) != nil
        )
        do {
            let sanitizedData = try JSONEncoder().encode(sanitized)
            userDefaults.set(sanitizedData, forKey: Self.settingsKey)
            // 让探针和下一次启动立即看到已清理的结果；UserDefaults 没有 throwing API。
            userDefaults.synchronize()
            print("[DiaryEncryption] 已将旧版敏感设置迁移到 Keychain，并清理 UserDefaults 明文")
        } catch {
            throw DiaryEncryptionError.keychainMigrationFailed("写入清理后的设置失败：\(error.localizedDescription)")
        }
    }

    private func validatePassword(_ password: String) throws {
        guard !password.isEmpty,
              !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DiaryEncryptionError.passwordEmpty
        }
        guard password.count >= Self.minimumPasswordLength else {
            throw DiaryEncryptionError.passwordTooShort(minimum: Self.minimumPasswordLength)
        }
    }

    private func migrateSecret(_ value: String, account: String) throws {
        if let existing = keychain.loadPassword(for: account), !constantTimeEqual(existing, value) {
            // 不覆盖已有钥匙串密码，也不删除 UserDefaults 中的旧值；让用户显式处理冲突。
            throw DiaryEncryptionError.keychainMigrationFailed("钥匙串中已有不同的 \(account)，已保留旧设置")
        }
        if keychain.loadPassword(for: account) == nil {
            do {
                try keychain.savePassword(value, for: account)
            } catch {
                throw DiaryEncryptionError.keychainMigrationFailed("\(account)：\(error.localizedDescription)")
            }
        }
    }

    private func persistNonSensitiveSettings(_ persistedSettings: PersistedDiaryEncryptionSettings) throws {
        do {
            let data = try JSONEncoder().encode(persistedSettings)
            userDefaults.set(data, forKey: Self.settingsKey)
            userDefaults.synchronize()
        } catch {
            throw DiaryEncryptionError.keychainMigrationFailed("写入非敏感设置失败：\(error.localizedDescription)")
        }
    }

    private func persistedSettingsFromDefaults() -> PersistedDiaryEncryptionSettings? {
        guard let raw = userDefaults.object(forKey: Self.settingsKey),
              let data = settingsData(from: raw) else { return nil }
        return try? JSONDecoder().decode(PersistedDiaryEncryptionSettings.self, from: data)
    }

    private func legacySettingsFromDefaults() -> LegacyDiaryEncryptionSettings? {
        guard let raw = userDefaults.object(forKey: Self.settingsKey),
              let data = settingsData(from: raw) else { return nil }
        return try? JSONDecoder().decode(LegacyDiaryEncryptionSettings.self, from: data)
    }

    private func settingsData(from raw: Any) -> Data? {
        if let data = raw as? Data { return data }
        if let string = raw as? String { return string.data(using: .utf8) }
        if JSONSerialization.isValidJSONObject(raw) {
            return try? JSONSerialization.data(withJSONObject: raw)
        }
        return nil
    }

    private func jsonContainsSensitiveSettings(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return true
        }
        return ["password", "securityQuestion", "securityAnswer"].contains {
            dictionary.keys.contains($0)
        }
    }

    // MARK: - 当前 AES-GCM 格式

    private func encrypt(_ text: String, password: String) throws -> String {
        let plaintext = Data(text.utf8)
        let salt = try secureRandomData(count: Self.currentSaltLength)
        let nonceData = try secureRandomData(count: Self.currentNonceLength)
        let key: SymmetricKey
        do {
            key = try deriveKey(
                password: password,
                salt: salt,
                iterations: Self.currentPBKDF2Iterations
            )
        } catch let error as DiaryEncryptionError {
            throw error
        } catch {
            throw DiaryEncryptionError.encryptionFailed(error.localizedDescription)
        }

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw DiaryEncryptionError.encryptionFailed("nonce 初始化失败：\(error.localizedDescription)")
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        } catch {
            throw DiaryEncryptionError.encryptionFailed(error.localizedDescription)
        }

        let verifier = try passwordVerifier(for: password)
        var payload = Data()
        payload.reserveCapacity(
            Self.currentMagic.count + 1 + 4 + Self.currentSaltLength
                + Self.currentNonceLength + sealedBox.ciphertext.count
                + Self.currentTagLength + Self.passwordVerifierLength
        )
        payload.append(Self.currentMagic)
        payload.append(Self.currentFormatVersion)
        appendUInt32(Self.currentPBKDF2Iterations, to: &payload)
        payload.append(salt)
        payload.append(nonceData)
        payload.append(sealedBox.ciphertext)
        payload.append(sealedBox.tag)
        payload.append(verifier)

        return Self.currentFormatPrefix + payload.base64EncodedString()
    }

    private func decrypt(_ encryptedText: String, password: String) throws -> String {
        if encryptedText.hasPrefix(Self.currentFormatPrefix) {
            return try decryptCurrentFormat(encryptedText, password: password)
        }

        let payload = legacyPayload(from: encryptedText)

        // 旧格式没有认证。应用自身有 Keychain 密码时先做一次精确比对，以便把
        // 错误密码标成“密码错误”；没有配置密码的独立旧样本只能按解密结果判断。
        if let storedPassword = keychain.loadPassword(for: Self.passwordAccount),
           !constantTimeEqual(storedPassword, password) {
            throw DiaryEncryptionError.wrongPassword
        }

        if let payload,
           let plaintext = decryptLegacyGCM(payload, password: password) {
            return plaintext
        }
        if let plaintext = decryptLegacyCBC(
            encryptedText,
            payload: payload ?? Data(),
            password: password
        ) {
            return plaintext
        }
        throw DiaryEncryptionError.corruptedData
    }

    private func decryptCurrentFormat(_ encryptedText: String, password: String) throws -> String {
        let encoded = String(encryptedText.dropFirst(Self.currentFormatPrefix.count))
        guard let payload = Data(base64Encoded: encoded) else {
            throw DiaryEncryptionError.corruptedData
        }

        let bytes = [UInt8](payload)
        let headerLength = Self.currentMagic.count + 1 + 4 + Self.currentSaltLength + Self.currentNonceLength
        let minimumLength = headerLength + Self.currentTagLength + Self.passwordVerifierLength
        guard bytes.count >= minimumLength,
              Array(bytes[0..<Self.currentMagic.count]) == [UInt8](Self.currentMagic),
              bytes[4] == Self.currentFormatVersion else {
            throw DiaryEncryptionError.corruptedData
        }

        let iterations = readUInt32(bytes, at: 5)
        guard iterations >= 1_000, iterations <= 2_000_000 else {
            throw DiaryEncryptionError.corruptedData
        }

        let saltStart = 9
        let saltEnd = saltStart + Self.currentSaltLength
        let nonceStart = saltEnd
        let nonceEnd = nonceStart + Self.currentNonceLength
        let salt = Data(bytes[saltStart..<saltEnd])
        let nonceData = Data(bytes[nonceStart..<nonceEnd])
        let verifierStart = bytes.count - Self.passwordVerifierLength
        let tagStart = verifierStart - Self.currentTagLength
        let ciphertext = Data(bytes[nonceEnd..<tagStart])
        let tag = Data(bytes[tagStart..<verifierStart])
        let storedVerifier = Data(bytes[verifierStart..<bytes.count])

        // 该 verifier 不依赖 envelope 的 salt/nonce。这样正确密码下的任意密文、
        // nonce、tag 或 salt 篡改都会落到 GCM/格式失败，而不是被误报为密码错误。
        let expectedVerifier: Data
        do {
            expectedVerifier = try passwordVerifier(for: password)
        } catch {
            throw DiaryEncryptionError.corruptedData
        }
        guard constantTimeEqual(storedVerifier, expectedVerifier) else {
            // 应用通常能从 Keychain 知道当前密码；若密码正确但 verifier 被改写，
            // 应报告数据损坏，而不是把篡改误报成密码错误。
            if let storedPassword = keychain.loadPassword(for: Self.passwordAccount),
               constantTimeEqual(storedPassword, password) {
                throw DiaryEncryptionError.corruptedData
            }
            throw DiaryEncryptionError.wrongPassword
        }

        let key: SymmetricKey
        do {
            key = try deriveKey(password: password, salt: salt, iterations: iterations)
        } catch {
            throw DiaryEncryptionError.corruptedData
        }

        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw DiaryEncryptionError.corruptedData
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                throw DiaryEncryptionError.corruptedData
            }
            return text
        } catch let error as DiaryEncryptionError {
            throw error
        } catch {
            throw DiaryEncryptionError.corruptedData
        }
    }

    private func passwordVerifier(for password: String) throws -> Data {
        let key = try deriveKey(
            password: password,
            salt: Self.passwordVerifierSalt,
            iterations: Self.passwordVerifierIterations
        )
        return Data(HMAC<SHA256>.authenticationCode(
            for: Self.passwordVerifierMessage,
            using: key
        ))
    }

    private func secureRandomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status: Int32 = data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return Int32(kCCParamError) }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw DiaryEncryptionError.encryptionFailed("安全随机数生成失败（status=\(status)）")
        }
        return data
    }

    private func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derived = Data(count: 32)
        let status: Int32 = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derived.withUnsafeMutableBytes { derivedBytes in
                    guard let passwordBase = passwordBytes.baseAddress?
                            .assumingMemoryBound(to: Int8.self),
                          let saltBase = saltBytes.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                          let derivedBase = derivedBytes.baseAddress?
                            .assumingMemoryBound(to: UInt8.self) else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBase,
                        passwordData.count,
                        saltBase,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedBase,
                        32
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw DiaryEncryptionError.keyDerivationFailed(status)
        }
        return SymmetricKey(data: derived)
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(Data(lhs.utf8), Data(rhs.utf8))
    }

    private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    // MARK: - 旧格式读取（只读兼容，写出始终使用 v2 GCM）

    private func legacyPayload(from text: String) -> Data? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["SND1:", "CBC1:", "CBC:", "v1:", "AES-CBC:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        if let data = Data(base64Encoded: value), !data.isEmpty {
            return data
        }
        // 兼容 URL-safe Base64；标准 Base64 仍由上面的严格路径优先处理。
        let normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        if let base64Data = Data(base64Encoded: padded) {
            return base64Data
        }
        return dataFromHex(value)
    }

    /// 兼容本项目历史版本实际写出的 `salt32 + AES-GCM combined`。
    private func decryptLegacyGCM(_ data: Data, password: String) -> String? {
        for saltLength in [32, 16] {
            let minimum = saltLength + 12 + 16
            guard data.count >= minimum else { continue }
            let salt = data.prefix(saltLength)
            let combined = data.subdata(in: saltLength..<data.count)
            for iterations in [Self.legacyPBKDF2Iterations, Self.currentPBKDF2Iterations] {
                guard let key = try? deriveKey(password: password, salt: Data(salt), iterations: iterations),
                      let box = try? AES.GCM.SealedBox(combined: combined),
                      let plaintext = try? AES.GCM.open(box, using: key),
                      let text = String(data: plaintext, encoding: .utf8) else {
                    continue
                }
                return text
            }
        }
        return nil
    }

    private struct LegacyCBCLayout {
        let salt: Data?
        let iv: Data
        let ciphertext: Data
        let iterations: UInt32?
    }

    /// 尝试常见的旧 CBC 排列：salt+iv+ciphertext、iv+salt+ciphertext，
    /// 以及把首块当 IV 的无 salt 变体。规范旧样本为 16-byte salt + 16-byte IV
    /// + AES-CBC ciphertext，PBKDF2-HMAC-SHA256 10,000 次。旧格式没有认证，只能在成功解密后
    /// 校验 UTF-8；CommonCrypto 负责处理 CBC 的 PKCS#7；新写入始终是带认证的 GCM。
    private func decryptLegacyCBC(
        _ text: String,
        payload: Data,
        password: String
    ) -> String? {
        var layouts = legacyCBCCandidates(from: payload)
        layouts.append(contentsOf: jsonLegacyCBCCandidates(from: text))

        let fixedSalt = Data(repeating: 0x53, count: 16)
        let directKey = SymmetricKey(data: SHA256.hash(data: Data(password.utf8)))

        for layout in layouts {
            let salts: [Data]
            if let salt = layout.salt {
                salts = [salt]
            } else {
                salts = [Data(repeating: 0, count: 16), fixedSalt]
            }

            var iterationValues = [Self.legacyPBKDF2Iterations, Self.currentPBKDF2Iterations]
            if let iterations = layout.iterations {
                iterationValues.insert(iterations, at: 0)
            }

            for salt in salts {
                for iterations in iterationValues {
                    if let key = try? deriveKey(password: password, salt: salt, iterations: iterations) {
                        if let plaintext = decryptCBC(
                            layout.ciphertext,
                            key: key,
                            iv: layout.iv,
                            usesPKCS7: true
                        ), let text = String(data: plaintext, encoding: .utf8) {
                            return text
                        }
                        if let plaintext = decryptCBC(
                            layout.ciphertext,
                            key: key,
                            iv: layout.iv,
                            usesPKCS7: false
                        ), let text = String(data: plaintext, encoding: .utf8) {
                            return text
                        }
                    }
                }
            }

            // 一些更早的原型直接对 UTF-8 密码做 SHA-256；只在没有 salt 的候选上尝试。
            if layout.salt == nil,
               let plaintext = decryptCBC(layout.ciphertext, key: directKey, iv: layout.iv, usesPKCS7: true),
               let text = String(data: plaintext, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private func legacyCBCCandidates(from data: Data) -> [LegacyCBCLayout] {
        var result: [LegacyCBCLayout] = []
        let count = data.count
        let zeroIV = Data(repeating: 0, count: 16)

        func append(_ salt: Data?, _ iv: Data, _ ciphertext: Data) {
            guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: 16) else { return }
            result.append(LegacyCBCLayout(
                salt: salt,
                iv: iv,
                ciphertext: ciphertext,
                iterations: nil
            ))
        }

        for saltLength in [16, 32] {
            // salt || iv || ciphertext
            if count >= saltLength + 32,
               (count - saltLength - 16).isMultiple(of: 16) {
                append(
                    Data(data.prefix(saltLength)),
                    Data(data[saltLength..<(saltLength + 16)]),
                    Data(data.dropFirst(saltLength + 16))
                )
            }

            // iv || salt || ciphertext
            if count >= 16 + saltLength + 16,
               (count - 16 - saltLength).isMultiple(of: 16) {
                append(
                    Data(data.subdata(in: 16..<(16 + saltLength))),
                    Data(data.prefix(16)),
                    Data(data.dropFirst(16 + saltLength))
                )
            }

            // salt || ciphertext with a fixed zero IV
            if count > saltLength,
               (count - saltLength).isMultiple(of: 16) {
                append(Data(data.prefix(saltLength)), zeroIV, Data(data.dropFirst(saltLength)))
            }
        }

        // iv || ciphertext with a conventional fixed salt
        if count >= 32, (count - 16).isMultiple(of: 16) {
            append(nil, Data(data.prefix(16)), Data(data.dropFirst(16)))
        }
        // ciphertext with a zero IV and no envelope
        if !data.isEmpty, count.isMultiple(of: 16) {
            append(nil, zeroIV, data)
        }
        return result
    }

    private func jsonLegacyCBCCandidates(from text: String) -> [LegacyCBCLayout] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return []
        }

        let salt = firstDataValue(in: dictionary, keys: ["salt", "keySalt"])
        let iv = firstDataValue(in: dictionary, keys: ["iv", "nonce", "initializationVector"])
        let ciphertext = firstDataValue(in: dictionary, keys: ["ciphertext", "encrypted", "data", "payload"])
        guard let iv, let ciphertext else { return [] }

        var iterations: UInt32?
        if let number = dictionary["iterations"] as? NSNumber {
            iterations = number.uint32Value
        }
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: 16) else { return [] }
        return [LegacyCBCLayout(salt: salt, iv: iv, ciphertext: ciphertext, iterations: iterations)]
    }

    private func firstDataValue(in dictionary: [String: Any], keys: [String]) -> Data? {
        for key in keys {
            if let value = dictionary[key] {
                if let data = value as? Data { return data }
                if let string = value as? String {
                    if let base64 = Data(base64Encoded: string) { return base64 }
                    if let hex = dataFromHex(string) { return hex }
                }
            }
        }
        return nil
    }

    private func dataFromHex(_ value: String) -> Data? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func decryptCBC(
        _ ciphertext: Data,
        key: SymmetricKey,
        iv: Data,
        usesPKCS7: Bool
    ) -> Data? {
        guard !ciphertext.isEmpty,
              ciphertext.count.isMultiple(of: 16),
              iv.count == 16 else { return nil }

        let keyData = key.withUnsafeBytes { Data($0) }
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status: Int32 = ciphertext.withUnsafeBytes { ciphertextBytes in
            keyData.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        guard let ciphertextBase = ciphertextBytes.baseAddress,
                              let keyBase = keyBytes.baseAddress,
                              let ivBase = ivBytes.baseAddress,
                              let outputBase = outputBytes.baseAddress else {
                            return Int32(kCCParamError)
                        }
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            usesPKCS7 ? CCOptions(kCCOptionPKCS7Padding) : CCOptions(0),
                            keyBase,
                            keyData.count,
                            ivBase,
                            ciphertextBase,
                            ciphertext.count,
                            outputBase,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, moved >= 0, moved <= outputCapacity else { return nil }
        let plaintext = Data(output.prefix(moved))
        // CommonCrypto's decrypt operation removes PKCS#7 padding when that
        // option is supplied; the raw output is already the unpadded plaintext.
        // With the option disabled, retain the raw bytes for old no-padding data.
        return plaintext
    }

    // MARK: - Codable 辅助类型（不修改共享 Diary 模型）

    private struct PersistedDiaryEncryptionSettings: Codable {
        let schemaVersion: Int
        let isEnabled: Bool
        let hasSecurityQuestion: Bool
        let hasSecurityAnswer: Bool
    }

    private struct LegacyDiaryEncryptionSettings: Codable {
        let isEnabled: Bool?
        let password: String?
        let securityQuestion: String?
        let securityAnswer: String?
    }
}
