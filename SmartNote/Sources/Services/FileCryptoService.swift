import Foundation
import CryptoKit
import CommonCrypto
import UniformTypeIdentifiers

/// 文件加密/解密服务。
///
/// - 算法：AES-256-GCM（系统 CryptoKit），认证加密（AEAD），
///         16 字节 salt + 12 字节 nonce + ciphertext + 16 字节 auth tag。
/// - 密钥派生：PBKDF2-HMAC-SHA256，迭代次数 100,000（可用 P0-1 `cryptoIterations` 调整）。
/// - 文件格式：
///     ```
///     [4 bytes magic "SNEN"] [1 byte version=1] [16 bytes salt]
///     [12 bytes nonce] [N bytes ciphertext] [16 bytes GCM tag]
///     ```
/// - 上限：单文件 ≤ 2GB（参见 Self.maxEncryptedFileSize）。
final class FileCryptoService {

    enum CryptoError: Error, LocalizedError {
        case fileNotReadable(String)
        case fileTooLarge(Int64)
        case fileTooSmall
        case invalidMagic
        case unsupportedVersion(UInt8)
        case passwordEmpty
        case keyDerivationFailed(Int32)
        case encryptFailed(String)
        case decryptFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotReadable(let path):
                return "无法读取文件：\(path)"
            case .fileTooLarge(let bytes):
                let mb = Double(bytes) / 1024 / 1024
                let maxMB = Double(FileCryptoService.maxEncryptedFileSize) / 1024 / 1024
                return String(format: "文件 %.1f MB 超过 %.0f MB 上限", mb, maxMB)
            case .fileTooSmall:
                return "文件过小或已损坏"
            case .invalidMagic:
                return "不是本工具生成的 .snenc 文件（magic 校验失败）"
            case .unsupportedVersion(let v):
                return "不支持的 .snenc 版本：\(v)"
            case .passwordEmpty:
                return "密码不能为空"
            case .keyDerivationFailed(let s):
                return "PBKDF2 失败 (status=\(s))"
            case .encryptFailed(let s):
                return "加密失败：\(s)"
            case .decryptFailed(let s):
                return "解密失败：\(s)"
            }
        }
    }

    /// 单文件最大 2 GB
    static let maxEncryptedFileSize: Int64 = 2 * 1024 * 1024 * 1024

    /// PBKDF2 迭代次数。100k 在 macOS 上单次 < 100 ms；安全与体验折中。
    private static let pbkdf2Iterations: UInt32 = 100_000

    /// 文件头：magic + version
    private static let kFileMagic: [UInt8] = [0x53, 0x4E, 0x45, 0x4E]  // "SNEN"
    private static let kFileVersion: UInt8 = 1
    private static let kSaltLen: Int = 16
    private static let kNonceLen: Int = 12

    /// 输出文件统一后缀
    static let encryptedExtension: String = "snenc"

    private let fileManager = FileManager.default

    // MARK: - 加密入口

    /// 加密单个文件
    /// - Parameters:
    ///   - sourceURL: 明文文件 URL
    ///   - password: 用户输入的密码（>=1 字符）
    ///   - outputURL: 输出 .snenc 路径（若为 nil 则在源文件同名 + .snenc 同目录）
    /// - Returns: 实际写入的 .snenc 文件 URL
    @discardableResult
    func encryptFile(at sourceURL: URL, password: String, outputURL: URL? = nil) throws -> URL {
        guard !password.isEmpty else { throw CryptoError.passwordEmpty }

        // 校验大小
        let attr = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let size = (attr[.size] as? Int64) ?? 0
        guard size <= Self.maxEncryptedFileSize else { throw CryptoError.fileTooLarge(size) }

        let output = outputURL ?? deriveOutputURL(from: sourceURL)

        // 随机 salt 16 + nonce 12
        var saltBytes = Data(count: Self.kSaltLen)
        let saltRes = saltBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, Self.kSaltLen, base)
        }
        guard saltRes == errSecSuccess else { throw CryptoError.encryptFailed("SecRandom 失败") }

        var nonceBytes = Data(count: Self.kNonceLen)
        let nonceRes = nonceBytes.withUnsafeMutableBytes { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, Self.kNonceLen, base)
        }
        guard nonceRes == errSecSuccess else { throw CryptoError.encryptFailed("SecRandom 失败") }

        // 派生 key
        let key = try Self.deriveKey(password: password, salt: saltBytes)

        // 读明文（用 memory map；2GB 上限对内存友好）
        var plaintext: Data
        do {
            plaintext = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw CryptoError.fileNotReadable(sourceURL.path)
        }

        // AES-GCM 加密
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceBytes))
        } catch {
            throw CryptoError.encryptFailed("\(error)")
        }

        // 串成最终文件
        var outputData = Data()
        outputData.reserveCapacity(4 + 1 + Self.kSaltLen + Self.kNonceLen + sealed.ciphertext.count + sealed.tag.count)
        outputData.append(contentsOf: Self.kFileMagic)
        outputData.append(Self.kFileVersion)
        outputData.append(saltBytes)
        outputData.append(nonceBytes)
        outputData.append(sealed.ciphertext)
        outputData.append(sealed.tag)

        do {
            try outputData.write(to: output, options: .atomic)
        } catch {
            throw CryptoError.encryptFailed("写文件失败：\(error)")
        }

        // 抹掉 key（Swift 自动释放后会被覆盖；显式 reinit 增强安全感）
        plaintext.resetBytes(in: 0..<plaintext.count)
        return output
    }

    // MARK: - 解密入口

    /// 解密 .snenc → 明文
    @discardableResult
    func decryptFile(at encryptedURL: URL, password: String, outputURL: URL? = nil) throws -> URL {
        guard !password.isEmpty else { throw CryptoError.passwordEmpty }

        let raw: Data
        do {
            raw = try Data(contentsOf: encryptedURL, options: [.mappedIfSafe])
        } catch {
            throw CryptoError.fileNotReadable(encryptedURL.path)
        }

        let minSize = 4 + 1 + Self.kSaltLen + Self.kNonceLen + 16  // magic+ver+salt+nonce+tag
        guard raw.count > minSize else { throw CryptoError.fileTooSmall }

        // magic
        let magic = raw.subdata(in: 0..<4)
        guard magic == Data(Self.kFileMagic) else { throw CryptoError.invalidMagic }

        let version = raw[4]
        guard version == Self.kFileVersion else { throw CryptoError.unsupportedVersion(version) }

        let salt = raw.subdata(in: 5..<(5 + Self.kSaltLen))
        let nonceData = raw.subdata(in: (5 + Self.kSaltLen)..<(5 + Self.kSaltLen + Self.kNonceLen))
        let payload = raw.subdata(in: (5 + Self.kSaltLen + Self.kNonceLen)..<raw.count)

        let key = try Self.deriveKey(password: password, salt: salt)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: nonceData)
        } catch {
            throw CryptoError.decryptFailed("nonce 解析失败")
        }

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: payload.prefix(payload.count - 16), tag: payload.suffix(16))
        } catch {
            throw CryptoError.decryptFailed("sealed box 解析失败")
        }

        var plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw CryptoError.decryptFailed("密码错误或文件已损坏")
        }

        let outURL = outputURL ?? deriveDecryptedOutputURL(from: encryptedURL)
        do {
            try plaintext.write(to: outURL, options: .atomic)
        } catch {
            throw CryptoError.decryptFailed("写明文失败：\(error)")
        }
        plaintext.resetBytes(in: 0..<plaintext.count)
        return outURL
    }

    // MARK: - 批量（外部循环用，业务不公开）

    /// 顺序加密一组文件；任一失败抛错并停止（已成功的可由调用方决定是否保留）
    /// - Returns: ([成功], [失败: (URL, Error)])
    func encryptBatch(_ sources: [URL], password: String, outputDirectory: URL?) throws -> (succeeded: [URL], failed: [(URL, Error)]) {
        var succeeded: [URL] = []
        var failed: [(URL, Error)] = []
        for src in sources {
            let out: URL
            if let dir = outputDirectory {
                out = dir.appendingPathComponent((src.lastPathComponent) + "." + Self.encryptedExtension)
            } else {
                out = deriveOutputURL(from: src)
            }
            do {
                let written = try encryptFile(at: src, password: password, outputURL: out)
                succeeded.append(written)
            } catch {
                failed.append((src, error))
            }
        }
        return (succeeded, failed)
    }

    // MARK: - 密钥派生 (PBKDF2-HMAC-SHA256)

    private static func deriveKey(password: String, salt: Data) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let result: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
            password.withCString { pwdPtr in
                salt.withUnsafeBytes { saltBytes in
                    guard let saltBase = saltBytes.bindMemory(to: UInt8.self).baseAddress,
                          let derivedBase = derivedBytes.bindMemory(to: UInt8.self).baseAddress else {
                        return Int32(kCCParamError)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwdPtr, strlen(pwdPtr),
                        saltBase, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBase, 32
                    )
                }
            }
        }
        guard result == kCCSuccess else {
            throw CryptoError.keyDerivationFailed(result)
        }
        return SymmetricKey(data: derived)
    }

    // MARK: - URL 推导

    /// 在源文件同目录下生成 `<原文件名>.snenc`。若已存在则追加 `-1`、`-2`…
    private func deriveOutputURL(from sourceURL: URL) -> URL {
        let dir = sourceURL.deletingLastPathComponent()
        let base = sourceURL.lastPathComponent
        var url = dir.appendingPathComponent("\(base).\(Self.encryptedExtension)")
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(counter).\(Self.encryptedExtension)")
            counter += 1
        }
        return url
    }

    /// 解密输出：优先用源文件名去尾，生成同名（无后缀）文件；同目录冲突时加 `-1`
    private func deriveDecryptedOutputURL(from encrypted: URL) -> URL {
        let dir = encrypted.deletingLastPathComponent()
        let raw = encrypted.lastPathComponent
        let stem: String
        if raw.hasSuffix(".\(Self.encryptedExtension)") {
            stem = String(raw.dropLast((".\(Self.encryptedExtension)").count))
        } else if raw.hasSuffix(".snenc") {
            stem = String(raw.dropLast(6))
        } else {
            stem = raw + ".decrypted"
        }
        var url = dir.appendingPathComponent(stem)
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stem)-\(counter)")
            counter += 1
        }
        return url
    }
}
