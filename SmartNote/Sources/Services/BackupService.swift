import Foundation

/// 备份与归档服务
///
/// - 角色：把 Application Support 整个目录打包成 zip 备份；同时支持列出/恢复/删除。
/// - 实现：完全用系统原生 API（`/usr/bin/ditto` + `FileManager`），不引第三方 zip 库。
/// - 时机：每次启动 App 时若检测到 schema 升级，先静默备份再迁移；
///   用户也可在「设置 → 备份与恢复」面板手动触发。
final class BackupService {

    /// 备份文件后缀
    static let backupExtension = "zip"

    /// 应用支持目录（被备份的根）
    private let sourceRoot: URL

    /// 备份目录（位于 Application Support/Backups 下）
    private let backupsRoot: URL

    private let fileManager = FileManager.default

    init(sourceRoot: URL) {
        self.sourceRoot = sourceRoot
        self.backupsRoot = sourceRoot.appendingPathComponent("Backups", isDirectory: true)
        ensureBackupsDirectoryExists()
    }

    private func ensureBackupsDirectoryExists() {
        if !fileManager.fileExists(atPath: backupsRoot.path) {
            try? fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        }
    }

    /// 生成备份 zip，返回文件 URL
    /// - Parameter label: 可选的人类可读标签（前缀）；空值时自动用时间戳
    /// - Throws: ditto 退出非 0 时抛出错误
    func makeBackup(label: String? = nil) throws -> URL {
        ensureBackupsDirectoryExists()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())

        let safeLabel: String = {
            guard let l = label?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty else {
                return ""
            }
            // 仅保留 ASCII 字母数字和短横线/下划线，避免 shell 转义问题
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.中_zh_CN")
            return String(l.unicodeScalars.filter { allowed.contains($0) || $0 == "_" }.prefix(40))
        }()

        let prefix = safeLabel.isEmpty ? "backup-\(stamp)" : "backup-\(safeLabel)-\(stamp)"
        // 避免前缀重复：同名文件已存在则追加 -N
        var zipURL = backupsRoot.appendingPathComponent("\(prefix).\(Self.backupExtension)")
        var counter = 1
        while fileManager.fileExists(atPath: zipURL.path) {
            zipURL = backupsRoot.appendingPathComponent("\(prefix)-\(counter).\(Self.backupExtension)")
            counter += 1
        }

        // 调系统 ditto 打 zip（lzfse + AES-256 加密 + keepParent）
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = [
            "-c", "-k",
            "--sequesterRsrc", "--keepParent",
            "--zlibCompressionLevel", "9",
            sourceRoot.path,
            zipURL.path
        ]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: errData, encoding: .utf8) ?? ""
            // 清理半成品
            try? fileManager.removeItem(at: zipURL)
            throw NSError(
                domain: "BackupService",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "ditto 退出码 \(task.terminationStatus)\(errString.isEmpty ? "" : "：\(errString)")"]
            )
        }

        return zipURL
    }

    /// 列出全部备份（按创建时间倒序）
    func listBackups() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: backupsRoot,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == Self.backupExtension }
            .sorted { (a, b) -> Bool in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return aDate > bDate
            }
    }

    /// 删除指定备份
    func deleteBackup(_ url: URL) throws {
        guard url.pathExtension == Self.backupExtension,
              url.deletingLastPathComponent().path == backupsRoot.path else {
            throw NSError(domain: "BackupService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "非受管备份，拒绝删除"])
        }
        try fileManager.removeItem(at: url)
    }

    /// 把备份 zip 解压到 **临时目录**（调用方需决定是否覆盖 sourceRoot）
    /// - Returns: 解压后的临时目录 URL；调用方负责清理
    func extractBackup(_ backupURL: URL) throws -> URL {
        guard backupURL.pathExtension == Self.backupExtension else {
            throw NSError(domain: "BackupService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "不是 .\(Self.backupExtension) 文件"])
        }
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("SmartNote-Restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", backupURL.path, tempDir.path]
        let stderr = Pipe()
        task.standardError = stderr
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            try? fileManager.removeItem(at: tempDir)
            let errString = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(
                domain: "BackupService",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "ditto 解压失败 (\(task.terminationStatus))\(errString.isEmpty ? "" : "：\(errString)")"]
            )
        }
        return tempDir
    }

    /// 备份根目录 URL，供 UI 展示
    var backupsDirectoryURL: URL { backupsRoot }
}
