import Foundation

/// 备份与恢复服务
///
/// - 角色：把数据根目录打包成未加密的 ZIP 备份；同时支持列出、恢复与删除。
/// - 实现：完全使用系统原生能力（`/usr/bin/ditto` + `FileManager`），不引入第三方依赖。
/// - 存储：备份目录固定放在数据根目录的同级目录，避免把历史备份递归打进新备份。
final class BackupService {

    /// 备份文件后缀
    static let backupExtension = "zip"

    /// 旧版曾把备份放在数据目录内；这里集中保留兼容名称。
    private static let legacyBackupsDirectoryName = "Backups"

    /// 新备份目录名后缀。与数据目录同级，例如 `SmartNote-Backups`。
    private static let externalBackupsDirectorySuffix = "Backups"

    /// 无法迁走的旧备份仍放在此目录下时，UI 会继续列出其中的 zip。
    private static let migratedBackupsDirectoryName = "Migrated Backups"

    /// 恢复前至少要找到一个已知受管数据文件。
    private static let requiredRestoreFileNames = [
        "materials.json",
        "settings.json",
        "whiteboards.json"
    ]

    /// 应用数据根目录（被备份和恢复的目标）
    private let sourceRoot: URL

    /// 独立备份目录（与 sourceRoot 同级，不在 sourceRoot 内）
    private let backupsRoot: URL

    /// 旧版位于 sourceRoot 内的备份目录，仅用于迁移和兼容展示
    private let legacyBackupsRoot: URL

    private let fileManager = FileManager.default
    private var directoryPreparationWarning: String?
    private var legacyMigrationWarning: String?

    init(sourceRoot: URL) {
        let standardizedSourceRoot = sourceRoot.standardizedFileURL
        self.sourceRoot = standardizedSourceRoot
        self.backupsRoot = standardizedSourceRoot
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(standardizedSourceRoot.lastPathComponent)-\(Self.externalBackupsDirectorySuffix)",
                isDirectory: true
            )
        self.legacyBackupsRoot = standardizedSourceRoot.appendingPathComponent(
            Self.legacyBackupsDirectoryName,
            isDirectory: true
        )
        refreshPreparationState()
    }

    // MARK: - 路径与准备

    /// 数据根目录，供恢复流程和存储统计统一取路径。
    var dataDirectoryURL: URL { sourceRoot }

    /// 备份根目录 URL，供 UI 展示。
    var backupsDirectoryURL: URL { backupsRoot }

    /// 旧备份目录 URL，仅用于兼容诊断。
    var legacyBackupsDirectoryURL: URL { legacyBackupsRoot }

    /// 统计数据目录占用空间；旧 Backups 即使尚未迁走也不计入应用数据。
    func dataStorageSize() -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let topLevelItems = try? fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return 0 }

        var totalSize: Int64 = 0
        for item in topLevelItems where !Self.isSamePath(item, legacyBackupsRoot) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }

            let urls: [URL]
            if isDirectory.boolValue,
               let enumerator = fileManager.enumerator(
                    at: item,
                    includingPropertiesForKeys: keys,
                    options: [.skipsPackageDescendants]
               ) {
                urls = enumerator.compactMap { $0 as? URL }
            } else {
                urls = [item]
            }

            for url in urls {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true {
                    totalSize += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return totalSize
    }

    /// 初始化、备份或刷新列表时发现的用户可见提示。
    var preparationWarnings: [String] {
        [directoryPreparationWarning, legacyMigrationWarning].compactMap { $0 }
    }

    private func refreshPreparationState() {
        do {
            try ensureBackupsDirectoryExists()
            directoryPreparationWarning = nil
        } catch {
            directoryPreparationWarning = "无法准备独立备份目录：\(error.localizedDescription)"
        }

        do {
            try migrateLegacyBackupsIfNeeded()
        } catch {
            legacyMigrationWarning = legacyMigrationMessage(for: error)
        }
    }

    private func ensureBackupsDirectoryExists() throws {
        try fileManager.createDirectory(at: backupsRoot, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: backupsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw serviceError(code: -10, message: "备份路径不是目录")
        }

        guard !Self.pathsContainEachOther(sourceRoot, backupsRoot) else {
            throw serviceError(code: -11, message: "数据目录与备份目录不能互相包含")
        }
    }

    /// `ditto` 没有排除单个子目录的参数，因此打包前把旧 Backups 整体迁出数据目录。
    /// 如果权限等原因导致无法迁出，则停止打包并让 UI 继续展示、恢复或删除旧文件。
    private func migrateLegacyBackupsIfNeeded() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyBackupsRoot.path, isDirectory: &isDirectory) else {
            legacyMigrationWarning = nil
            return
        }
        guard isDirectory.boolValue else {
            throw serviceError(code: -12, message: "旧 Backups 路径不是目录")
        }
        guard directoryPreparationWarning == nil else {
            throw serviceError(code: -13, message: "独立备份目录尚不可用")
        }

        let migratedContainer = backupsRoot.appendingPathComponent(
            Self.migratedBackupsDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: migratedContainer, withIntermediateDirectories: true)

        let destination = migratedContainer.appendingPathComponent(
            "\(Self.legacyBackupsDirectoryName)-\(Self.timestamp())-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try fileManager.moveItem(at: legacyBackupsRoot, to: destination)
        legacyMigrationWarning = nil
    }

    private func legacyMigrationMessage(for error: Error) -> String {
        "旧备份未能迁出数据目录，仍保留在 \(legacyBackupsRoot.path)，可继续恢复或删除；迁移提示：\(error.localizedDescription)"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func pathsContainEachOther(_ lhs: URL, _ rhs: URL) -> Bool {
        isSamePath(lhs, rhs)
            || isStrictDescendant(lhs, of: rhs)
            || isStrictDescendant(rhs, of: lhs)
    }

    private static func isSamePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let parentComponents = parent.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return Array(childComponents.prefix(parentComponents.count)) == parentComponents
    }

    private func isManagedBackupURL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == Self.backupExtension else { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return [backupsRoot, legacyBackupsRoot].contains { root in
            let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
            return parent.path == resolvedRoot.path || Self.isStrictDescendant(parent, of: resolvedRoot)
        }
    }

    private func serviceError(code: Int, message: String) -> NSError {
        NSError(
            domain: "BackupService",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    // MARK: - 备份

    /// 生成未加密的 ZIP 备份，返回文件 URL。
    /// 不自动删除历史备份，避免用户未明确确认时丢失可能重要的数据。
    func makeBackup(label: String? = nil) throws -> URL {
        refreshPreparationState()
        if let warning = directoryPreparationWarning {
            throw serviceError(code: -20, message: warning)
        }
        if let warning = legacyMigrationWarning {
            throw serviceError(code: -21, message: warning)
        }

        // 这是显式排除：旧目录仍存在时绝不能启动 ditto，防止历史 zip 递归进入新 zip。
        guard !fileManager.fileExists(atPath: legacyBackupsRoot.path) else {
            throw serviceError(code: -22, message: "旧 Backups 目录仍在数据目录内，已停止打包以避免递归膨胀")
        }
        try ensureBackupsDirectoryExists()

        let safeLabel: String = {
            guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else {
                return ""
            }
            // 仅保留安全字符，避免路径与命令行转义问题。
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.中_zh_CN")
            return String(label.unicodeScalars.filter { allowed.contains($0) || $0 == "_" }.prefix(40))
        }()

        let prefix = safeLabel.isEmpty
            ? "backup-\(Self.timestamp())"
            : "backup-\(safeLabel)-\(Self.timestamp())"
        var zipURL = backupsRoot.appendingPathComponent("\(prefix).\(Self.backupExtension)")
        var counter = 1
        while fileManager.fileExists(atPath: zipURL.path) {
            zipURL = backupsRoot.appendingPathComponent("\(prefix)-\(counter).\(Self.backupExtension)")
            counter += 1
        }

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

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            try? fileManager.removeItem(at: zipURL)
            throw error
        }

        guard task.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: errData, encoding: .utf8) ?? ""
            try? fileManager.removeItem(at: zipURL)
            throw serviceError(
                code: Int(task.terminationStatus),
                message: "ditto 退出码 \(task.terminationStatus)\(errString.isEmpty ? "" : "：\(errString)")"
            )
        }

        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw serviceError(code: -23, message: "ditto 未生成备份文件")
        }
        return zipURL
    }

    // MARK: - 列表与删除

    /// 列出独立目录及尚未迁走的旧目录中的全部备份，按创建时间倒序。
    func listBackups() -> [URL] {
        refreshPreparationState()

        var seenPaths = Set<String>()
        var backups: [URL] = []
        for root in [backupsRoot, legacyBackupsRoot] {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .creationDateKey,
                    .contentModificationDateKey,
                    .fileSizeKey
                ],
                options: []
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == Self.backupExtension {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey])
                guard values?.isRegularFile != false else { continue }
                if seenPaths.insert(url.standardizedFileURL.path).inserted {
                    backups.append(url)
                }
            }
        }

        return backups.sorted { lhs, rhs in
            let lhsDate = creationOrModificationDate(for: lhs)
            let rhsDate = creationOrModificationDate(for: rhs)
            if lhsDate == rhsDate {
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
            return lhsDate > rhsDate
        }
    }

    private func creationOrModificationDate(for url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    /// 删除独立目录或兼容旧目录中的指定备份。
    func deleteBackup(_ url: URL) throws {
        guard url.pathExtension.lowercased() == Self.backupExtension,
              isManagedBackupURL(url) else {
            throw serviceError(code: -30, message: "非受管备份，拒绝删除")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw serviceError(code: -31, message: "备份文件不存在")
        }
        try fileManager.removeItem(at: url)

        // 旧目录中的最后一个 zip 被显式删除后，顺带清理空目录。
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL == legacyBackupsRoot.standardizedFileURL,
           let contents = try? fileManager.contentsOfDirectory(atPath: parent.path),
           contents.isEmpty {
            try? fileManager.removeItem(at: parent)
        }
    }

    // MARK: - 恢复

    /// 把备份解压到独立临时目录，规范化顶层目录并校验关键数据文件。
    /// - Returns: 可直接作为新数据根目录使用的临时目录；调用方负责切换或清理。
    func extractBackup(_ backupURL: URL) throws -> URL {
        guard isManagedBackupURL(backupURL) else {
            throw serviceError(code: -40, message: "不是受管的 .\(Self.backupExtension) 文件")
        }
        guard fileManager.fileExists(atPath: backupURL.path) else {
            throw serviceError(code: -41, message: "备份文件不存在")
        }

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(
            "SmartNote-Restore-\(UUID().uuidString)",
            isDirectory: true
        )
        guard !Self.isStrictDescendant(tempDir, of: sourceRoot) else {
            throw serviceError(code: -42, message: "恢复临时目录不能位于数据目录内")
        }
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-x", "-k", backupURL.path, tempDir.path]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            try? fileManager.removeItem(at: tempDir)
            throw error
        }

        guard task.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errString = String(data: errData, encoding: .utf8) ?? ""
            try? fileManager.removeItem(at: tempDir)
            throw serviceError(
                code: Int(task.terminationStatus),
                message: "ditto 解压失败 (\(task.terminationStatus))\(errString.isEmpty ? "" : "：\(errString)")"
            )
        }

        do {
            try normalizeExtractedDirectory(tempDir)
            try validateRestoreDirectory(tempDir)
            return tempDir
        } catch {
            try? fileManager.removeItem(at: tempDir)
            throw error
        }
    }

    /// 兼容带 `SmartNote` / `SmartNode` 一层父目录的旧备份。
    private func normalizeExtractedDirectory(_ tempDir: URL) throws {
        if containsManagedDataFile(tempDir) { return }

        let children = try fileManager.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        let meaningfulChildren = children.filter {
            $0.lastPathComponent != "__MACOSX" && !$0.lastPathComponent.hasPrefix(".")
        }
        guard meaningfulChildren.count == 1 else {
            throw serviceError(code: -43, message: "无法识别备份的数据根目录")
        }

        let wrapper = meaningfulChildren[0]
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: wrapper.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              containsManagedDataFile(wrapper) else {
            throw serviceError(code: -44, message: "备份缺少已知数据文件")
        }

        let wrapperChildren = try fileManager.contentsOfDirectory(
            at: wrapper,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in wrapperChildren {
            let destination = tempDir.appendingPathComponent(child.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw serviceError(code: -45, message: "解压目录存在名称冲突")
            }
            try fileManager.moveItem(at: child, to: destination)
        }
        try fileManager.removeItem(at: wrapper)
    }

    private func validateRestoreDirectory(_ directory: URL) throws {
        guard containsManagedDataFile(directory) else {
            let names = Self.requiredRestoreFileNames.joined(separator: " / ")
            throw serviceError(code: -46, message: "备份中未找到受管数据文件（\(names)），已取消恢复")
        }
    }

    private func containsManagedDataFile(_ directory: URL) -> Bool {
        Self.requiredRestoreFileNames.contains { fileName in
            let url = directory.appendingPathComponent(fileName)
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
    }

    /// 用已经校验并规范化的临时目录替换数据根目录。
    ///
    /// 切换时先把整个旧目录原子重命名，再把新目录移动到原路径；新目录移动或复验失败时立即回滚。
    /// 调用方必须在成功后退出进程，避免后台服务把旧内存状态写回磁盘。
    func replaceDataDirectory(withExtractedBackupAt restoredDirectory: URL) throws {
        let restoredRoot = restoredDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: restoredRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw serviceError(code: -50, message: "恢复临时目录不存在")
        }
        guard !Self.isSamePath(restoredRoot, sourceRoot),
              !Self.isStrictDescendant(restoredRoot, of: sourceRoot),
              !Self.isStrictDescendant(sourceRoot, of: restoredRoot) else {
            throw serviceError(code: -51, message: "恢复目录与当前数据目录不安全地重叠")
        }
        try validateRestoreDirectory(restoredRoot)

        let parent = sourceRoot.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let oldRoot = parent.appendingPathComponent(
            "\(sourceRoot.lastPathComponent).restore-old-\(Self.timestamp())-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        let failedRoot = parent.appendingPathComponent(
            "\(sourceRoot.lastPathComponent).restore-failed-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )

        let hadOldRoot = fileManager.fileExists(atPath: sourceRoot.path)
        if hadOldRoot {
            do {
                try fileManager.moveItem(at: sourceRoot, to: oldRoot)
            } catch {
                throw serviceError(
                    code: -52,
                    message: "无法暂存当前数据，原数据未改动：\(error.localizedDescription)"
                )
            }
        }

        do {
            try fileManager.moveItem(at: restoredRoot, to: sourceRoot)
            try validateRestoreDirectory(sourceRoot)
        } catch {
            try rollbackRestore(
                oldRoot: oldRoot,
                failedRoot: failedRoot,
                hadOldRoot: hadOldRoot,
                originalError: error
            )
            throw serviceError(
                code: -53,
                message: "恢复切换失败，已回滚原数据：\(error.localizedDescription)"
            )
        }

        if hadOldRoot {
            do {
                try fileManager.removeItem(at: oldRoot)
            } catch {
                // 新数据已完整落位，旧目录删除失败时保留它，优先保证现有数据可继续启动。
                print("[BackupService] 恢复成功，但旧数据目录清理失败：\(error.localizedDescription)")
            }
        }
    }

    private func rollbackRestore(
        oldRoot: URL,
        failedRoot: URL,
        hadOldRoot: Bool,
        originalError: Error
    ) throws {
        if fileManager.fileExists(atPath: sourceRoot.path) {
            do {
                try fileManager.moveItem(at: sourceRoot, to: failedRoot)
            } catch {
                throw serviceError(
                    code: -54,
                    message: "恢复失败且无法移走不完整的新数据；原数据仍保留在 \(oldRoot.path)。原始错误：\(originalError.localizedDescription)"
                )
            }
        }

        if hadOldRoot {
            do {
                try fileManager.moveItem(at: oldRoot, to: sourceRoot)
            } catch {
                throw serviceError(
                    code: -55,
                    message: "恢复失败且回滚未完成；原数据仍保留在 \(oldRoot.path)。原始错误：\(originalError.localizedDescription)"
                )
            }
        }
        try? fileManager.removeItem(at: failedRoot)
    }
}
