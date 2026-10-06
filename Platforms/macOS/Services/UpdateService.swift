import Foundation
import SwiftUI
import AppKit
import UserNotifications

@MainActor
final class UpdateService: ObservableObject {
    enum Channel: String, Codable, CaseIterable {
        case latest
        case prerelease
    }

    struct Asset: Codable {
        let name: String
        let browser_download_url: String
    }

    struct ReleaseInfo: Codable {
        let id: Int
        let tag_name: String?
        let name: String?
        let prerelease: Bool
        let published_at: String?
        let assets: [Asset]
    }

    private struct ValidatedApp {
        let url: URL
        let bundleIdentifier: String
        let versionComponents: [Int]
        let totalFileSize: Int64
        let fileCount: Int
    }

    /// 普通 macOS App 明显大于这个值；下限用于拦截 HTML 错误页、截断包和空壳。
    static let defaultMinimumAppSize: Int64 = 5 * 1_024 * 1_024

    var owner: String
    var repo: String

    @Published var latestCheckedRelease: ReleaseInfo?
    /// 自动检查只记录候选版本；必须由用户点击“立即更新”才会进入下载与安装流程。
    @Published var pendingRelease: ReleaseInfo?
    @Published var lastError: String?
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double? = nil // 0.0 - 1.0
    @Published var logs: [String] = []
    @Published var lastInstalledURL: URL? = nil

    private let applicationsDirectoryOverride: URL?
    private let expectedBundleIdentifierOverride: String?
    private let currentVersionOverride: String?
    private let minimumAppSize: Int64
    private let temporaryDirectoryOverride: URL?
    private let launchApplicationOverride: (@MainActor (URL) async throws -> Void)?
    private let terminateApplicationOverride: (@MainActor () -> Void)?

    var currentAppVersion: String {
        currentVersionOverride
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "未知"
    }

    init(
        owner: String = "XiJian-Development-Group",
        repo: String = "SmartNote",
        applicationsDirectory: URL? = nil,
        expectedBundleIdentifier: String? = nil,
        currentVersion: String? = nil,
        minimumAppSize: Int64 = 5 * 1_024 * 1_024,
        temporaryDirectory: URL? = nil,
        launchApplication: (@MainActor (URL) async throws -> Void)? = nil,
        terminateApplication: (@MainActor () -> Void)? = nil
    ) {
        self.owner = owner
        self.repo = repo
        self.applicationsDirectoryOverride = applicationsDirectory
        self.expectedBundleIdentifierOverride = expectedBundleIdentifier
        self.currentVersionOverride = currentVersion
        self.minimumAppSize = max(1, minimumAppSize)
        self.temporaryDirectoryOverride = temporaryDirectory
        self.launchApplicationOverride = launchApplication
        self.terminateApplicationOverride = terminateApplication
    }

    func isUpdateAvailable(_ release: ReleaseInfo) -> Bool {
        guard
            let tag = release.tag_name,
            let releaseVersion = numericVersionComponents(tag),
            let currentVersion = numericVersionComponents(currentAppVersion)
        else {
            return false
        }
        return compare(releaseVersion, currentVersion) == .orderedDescending
    }

    /// Update the target repository used for checks/downloads.
    func updateRepository(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    /// Download a ZIP, extract it into a fresh temporary directory, validate it, and only then install it.
    /// `autoInstall: false` is download/extract-only and never changes the existing application.
    func performDownloadAndInstall(release: ReleaseInfo, autoInstall: Bool = false) async throws -> URL? {
        guard !isDownloading else {
            throw updateError("已有更新任务正在进行，请稍后再试。", code: 10)
        }
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else {
            throw updateError("该发布版本中没有可用的 ZIP 更新包。", code: 11)
        }
        guard let assetURL = URL(string: asset.browser_download_url), assetURL.scheme == "https" else {
            throw updateError("GitHub 更新下载地址无效。", code: 12)
        }

        // 本项目目前没有代码签名信任链。这里只能验证包的结构、身份标识、版本和体积，
        // 可拦截下载损坏、Bundle ID 不同的其他 App 与降级包，但不能替代开发者签名校验。
        logs.append("安全限制：更新仅校验包结构、Info.plist、Bundle ID、版本和体积；没有代码签名校验体系，不能完全替代签名验证。")

        logs.append("开始下载：\(assetURL.absoluteString)")
        isDownloading = true
        downloadProgress = 0.0
        defer {
            isDownloading = false
            downloadProgress = nil
        }

        let downloaded = try await downloadAsset(assetURL) { [weak self] progress in
            // Keep this progress handler synchronous; dispatch to the main actor from here.
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        // 每次使用独立临时目录，既避免复用旧解压物，也让验证发生在任何目标目录改动之前。
        logs.append("下载完成，开始解压到临时目录：\(downloaded.path)")
        let unzipped = try unzip(at: downloaded)
        logs.append("解压完成：\(unzipped.path)")

        guard autoInstall else { return unzipped }

        do {
            let installed = try await installUnzippedApp(at: unzipped)
            logs.append("验证、切换并启动新版本成功：\(installed.path)")
            return installed
        } catch {
            logs.append("安装失败：\(error.localizedDescription)")
            // rethrow for UI to handle. The extracted folder is retained for manual recovery.
            throw error
        }
    }

    private func isValidRepositoryComponent(_ value: String) -> Bool {
        guard (1...100).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let asciiValue = scalar.value
            return (asciiValue >= 65 && asciiValue <= 90)
                || (asciiValue >= 97 && asciiValue <= 122)
                || (asciiValue >= 48 && asciiValue <= 57)
                || asciiValue == 46
                || asciiValue == 95
                || asciiValue == 45
        }
    }

    private func repositoryInputError(_ component: String) -> NSError {
        NSError(
            domain: "UpdateService",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(component)无效：仅允许 A-Z、a-z、0-9、点、下划线和连字符，长度为 1...100"]
        )
    }

    func checkForUpdate(channel: Channel) async throws -> ReleaseInfo? {
        lastError = nil
        let session = URLSession.shared
        guard isValidRepositoryComponent(owner) else {
            throw repositoryInputError("更新仓库所有者")
        }
        guard isValidRepositoryComponent(repo) else {
            throw repositoryInputError("更新仓库名称")
        }
        if channel == .latest {
            guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
                throw updateError("GitHub 更新地址无效。", code: 2)
            }
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            let release = try decoder.decode(ReleaseInfo.self, from: data)
            latestCheckedRelease = release
            return release
        } else {
            guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases") else {
                throw updateError("GitHub 更新地址无效。", code: 2)
            }
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            let releases: [ReleaseInfo] = try decoder.decode([ReleaseInfo].self, from: data)
            let prereleases = releases.filter { $0.prerelease }
            let sorted = prereleases.sorted { ($0.published_at ?? "") > ($1.published_at ?? "") }
            let release = sorted.first
            latestCheckedRelease = release
            return release
        }
    }

    func downloadAsset(_ assetURL: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        // Use URLSession with delegate to report progress.
        let destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SmartNoteUpdates", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let tempFile = destDir.appendingPathComponent(
            "SmartNoteUpdate-\(UUID().uuidString)-\(assetURL.lastPathComponent)",
            isDirectory: false
        )

        final class DLDelegate: NSObject, URLSessionDownloadDelegate {
            let progressHandler: ((Double) -> Void)?
            let completion: (Result<URL, Error>) -> Void

            init(progress: ((Double) -> Void)?, completion: @escaping (Result<URL, Error>) -> Void) {
                self.progressHandler = progress
                self.completion = completion
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
                guard totalBytesExpectedToWrite > 0 else { return }
                let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                DispatchQueue.main.async {
                    self.progressHandler?(progress)
                }
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                completion(.success(location))
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error {
                    completion(.failure(error))
                }
            }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = DLDelegate(progress: progress) { result in
                switch result {
                case .success(let temporaryURL):
                    do {
                        // The URLSession temporary file is no longer valid after this callback.
                        // Use a unique destination so an update attempt never deletes an earlier download.
                        try FileManager.default.moveItem(at: temporaryURL, to: tempFile)
                        continuation.resume(returning: tempFile)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: assetURL)
            task.resume()
        }
    }

    func unzip(at zipURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let extractionParent = temporaryDirectoryOverride ?? fileManager.temporaryDirectory
        let destination = extractionParent.appendingPathComponent(
            "SmartNoteUpdate-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        // ditto is part of macOS and extracts into the already-created, unique directory.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw updateError("更新 ZIP 无法完整解压（ditto 退出码 \(process.terminationStatus)）。", code: Int(process.terminationStatus))
        }
        return destination
    }

    /// Validate every rule before touching the destination directory.
    func validateUnzippedApp(at folderURL: URL) throws -> URL {
        try validatedApp(at: folderURL).url
    }

    /// Copy to a same-volume sidecar, verify the copy, atomically rename directories, launch, then remove the old app.
    /// Every failure before a successful launch leaves the old app in place or restores it under its original name.
    func installUnzippedApp(at folderURL: URL) async throws -> URL {
        let fileManager = FileManager.default
        let applicationsDirectory = applicationsDirectoryOverride
            ?? URL(fileURLWithPath: "/Applications", isDirectory: true)
        let source = try validatedApp(at: folderURL)
        let destination = applicationsDirectory.appendingPathComponent(
            source.url.lastPathComponent,
            isDirectory: true
        )

        // Check this before creating a sidecar or touching the current app. Never request elevation here.
        try ensureTargetDirectoryIsWritable(applicationsDirectory, sourceURL: source.url, destinationURL: destination)

        let sidecar = transactionURL(for: destination, kind: "new")
        do {
            // The sidecar is a sibling of the destination, so copy and subsequent renames stay on one volume.
            try fileManager.copyItem(at: source.url, to: sidecar)
        } catch {
            throw manualInstallError(
                sourceURL: source.url,
                destinationURL: destination,
                reason: "无法写入目标目录：\(error.localizedDescription)"
            )
        }
        logs.append("已复制到同卷旁路文件：\(sidecar.path)")

        do {
            let copied = try validatedAppBundle(at: sidecar)
            // Re-read Bundle data and compare the copied tree size/count to catch a partial or altered copy.
            guard
                copied.bundleIdentifier == source.bundleIdentifier,
                copied.versionComponents == source.versionComponents,
                copied.totalFileSize == source.totalFileSize,
                copied.fileCount == source.fileCount
            else {
                throw updateError("旁路副本与已验证的更新包不一致，现有 App 未被改动。", code: 22)
            }
        } catch {
            preserveAside(sidecar, kind: "invalid")
            throw error
        }

        let oldAppBackup = transactionURL(for: destination, kind: "old")
        let hasExistingApp = fileManager.fileExists(atPath: destination.path)
        var backupURL: URL?

        if hasExistingApp {
            do {
                // Never delete the old app first. A same-volume rename is atomic and leaves a rollback copy.
                try fileManager.moveItem(at: destination, to: oldAppBackup)
                backupURL = oldAppBackup
                logs.append("旧版本已改名保留：\(oldAppBackup.path)")
            } catch {
                preserveAside(sidecar, kind: "failed")
                throw manualInstallError(
                    sourceURL: source.url,
                    destinationURL: destination,
                    reason: "无法重命名旧版本：\(error.localizedDescription)"
                )
            }
        }

        do {
            try fileManager.moveItem(at: sidecar, to: destination)
        } catch {
            let switchError = error
            preserveAside(sidecar, kind: "failed")
            var rollbackNote = ""
            if let backupURL {
                do {
                    try fileManager.moveItem(at: backupURL, to: destination)
                    rollbackNote = "旧版本已恢复到原位置。"
                } catch {
                    rollbackNote = "旧版本仍保留在 \(backupURL.path)，请手动恢复。"
                }
            } else {
                rollbackNote = "原先没有旧版本。"
            }
            throw updateError("新版切换失败：\(switchError.localizedDescription)。\(rollbackNote)", code: 23)
        }

        logs.append("新版已就位：\(destination.path)")
        do {
            try await launchInstalledApp(at: destination)
            logs.append("新版本已成功启动：\(destination.path)")
        } catch {
            throw rollbackAfterLaunchFailure(
                launchError: error,
                destinationURL: destination,
                backupURL: backupURL
            )
        }

        // Deleting the old app is deliberately last: launch failure must still be recoverable.
        if let backupURL {
            do {
                try fileManager.removeItem(at: backupURL)
                logs.append("新版本启动成功后已清理旧版本备份。")
            } catch {
                logs.append("新版本已启动，但无法清理旧版本备份 \(backupURL.path)：\(error.localizedDescription)")
            }
        }

        lastInstalledURL = destination
        // Give the newly launched process a brief head start before closing the old process.
        try? await Task.sleep(nanoseconds: 500_000_000)
        terminateCurrentApplication()
        return destination
    }

    private func validatedApp(at folderURL: URL) throws -> ValidatedApp {
        let appURL = try uniqueAppURL(in: folderURL)
        return try validatedAppBundle(at: appURL)
    }

    private func validatedAppBundle(at appURL: URL) throws -> ValidatedApp {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)

        guard let infoValues = try? infoURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              infoValues.isRegularFile == true,
              infoValues.isSymbolicLink != true else {
            throw updateError("App 的 Info.plist 缺失、无效或是符号链接，拒绝安装。", code: 20)
        }

        let infoData: Data
        do {
            infoData = try Data(contentsOf: infoURL)
        } catch {
            throw updateError("无法读取 App 的 Info.plist，可能已损坏：\(error.localizedDescription)", code: 20)
        }
        guard !infoData.isEmpty else {
            throw updateError("App 的 Info.plist 为空或残缺，拒绝安装。", code: 20)
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil)
        } catch {
            throw updateError("App 的 Info.plist 无法解析，可能已损坏：\(error.localizedDescription)", code: 20)
        }
        guard let info = propertyList as? [String: Any] else {
            throw updateError("App 的 Info.plist 不是完整字典，拒绝安装。", code: 20)
        }
        guard let packageType = info["CFBundlePackageType"] as? String, packageType == "APPL" else {
            throw updateError("下载内容不是有效的 macOS App（Info.plist 缺少 APPL 包类型），拒绝安装。", code: 20)
        }
        guard let bundleIdentifier = info["CFBundleIdentifier"] as? String, !bundleIdentifier.isEmpty else {
            throw updateError("App 的 Info.plist 缺少有效的 Bundle Identifier，拒绝安装。", code: 20)
        }
        guard let versionString = info["CFBundleShortVersionString"] as? String,
              let versionComponents = numericVersionComponents(versionString) else {
            throw updateError("App 的 Info.plist 缺少有效的 CFBundleShortVersionString，拒绝安装。", code: 20)
        }
        guard let executableName = info["CFBundleExecutable"] as? String, !executableName.isEmpty else {
            throw updateError("App 的 Info.plist 缺少有效的 CFBundleExecutable，拒绝安装。", code: 20)
        }
        try validateExecutable(named: executableName, in: appURL)

        guard let expectedBundleIdentifier = expectedBundleIdentifierOverride ?? Bundle.main.bundleIdentifier,
              !expectedBundleIdentifier.isEmpty else {
            throw updateError("无法读取当前 App 的 Bundle Identifier，无法安全验证更新包。", code: 21)
        }
        guard bundleIdentifier == expectedBundleIdentifier else {
            throw updateError(
                "Bundle Identifier 不匹配：下载包为 \(bundleIdentifier)，当前 App 为 \(expectedBundleIdentifier)。现有 App 未被改动。",
                code: 21
            )
        }

        guard let currentVersionString = currentVersionOverride
                ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
              let currentVersion = numericVersionComponents(currentVersionString) else {
            throw updateError("无法读取当前 App 版本，无法安全验证是否允许升级。", code: 21)
        }
        guard compare(versionComponents, currentVersion) != .orderedAscending else {
            throw updateError(
                "禁止降级：下载版本 \(versionString) 低于当前版本 \(currentVersionString)。现有 App 未被改动。",
                code: 21
            )
        }

        let size = try appMetrics(at: appURL)
        guard size.totalFileSize > minimumAppSize else {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let actual = formatter.string(fromByteCount: size.totalFileSize)
            let minimum = formatter.string(fromByteCount: minimumAppSize)
            throw updateError("App 体积仅 \(actual)，低于安全下限 \(minimum)，可能是 HTML 错误页、空壳或截断包。现有 App 未被改动。", code: 24)
        }

        return ValidatedApp(
            url: appURL,
            bundleIdentifier: bundleIdentifier,
            versionComponents: versionComponents,
            totalFileSize: size.totalFileSize,
            fileCount: size.fileCount
        )
    }

    private func uniqueAppURL(in folderURL: URL) throws -> URL {
        let fileManager = FileManager.default
        var rootIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw updateError("解压目录不存在或无效。", code: 19)
        }

        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw updateError("无法检查解压目录内容。", code: 19)
        }

        var apps: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            } catch {
                throw updateError("无法检查下载内容中的 \(url.lastPathComponent)：\(error.localizedDescription)", code: 19)
            }
            guard values.isSymbolicLink != true else {
                throw updateError("下载内容中的 \(url.lastPathComponent) 是符号链接，拒绝安装。", code: 19)
            }
            guard values.isDirectory == true else {
                throw updateError("下载内容中的 .app 不是目录，拒绝安装。", code: 19)
            }
            apps.append(url)
            // Do not count helper .app bundles nested inside the one top-level application.
            enumerator.skipDescendants()
        }

        guard !apps.isEmpty else {
            throw updateError("下载内容中未找到 .app，现有 App 未被改动。", code: 19)
        }
        guard apps.count == 1 else {
            throw updateError("下载内容中发现了 \(apps.count) 个 .app，无法确认唯一更新目标。现有 App 未被改动。", code: 19)
        }
        return apps[0]
    }

    private func validateExecutable(named executableName: String, in appURL: URL) throws {
        let macOSDirectory = appURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let executableURL = macOSDirectory.appendingPathComponent(executableName, isDirectory: false)
        let rootPath = appURL.standardizedFileURL.path + "/"
        let executablePath = executableURL.standardizedFileURL.path
        guard executablePath.hasPrefix(rootPath), executablePath != appURL.standardizedFileURL.path else {
            throw updateError("CFBundleExecutable 指向 App 包外部，拒绝安装。", code: 20)
        }
        guard let values = try? executableURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw updateError("Info.plist 指定的 App 可执行文件缺失或无效，拒绝安装。", code: 20)
        }
    }

    private func appMetrics(at appURL: URL) throws -> (totalFileSize: Int64, fileCount: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            throw updateError("无法统计 App 体积。", code: 24)
        }
        var totalFileSize: Int64 = 0
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw updateError("无法读取 App 内文件大小，可能已损坏。", code: 24)
            }
            let (sum, overflow) = totalFileSize.addingReportingOverflow(Int64(fileSize))
            guard !overflow else {
                throw updateError("App 体积异常，无法安全验证。", code: 24)
            }
            totalFileSize = sum
            fileCount += 1
        }
        return (totalFileSize, fileCount)
    }

    private func numericVersionComponents(_ rawValue: String) -> [Int]? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else {
                return nil
            }
            components.append(number)
        }
        return components
    }

    private func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private func ensureTargetDirectoryIsWritable(
        _ applicationsDirectory: URL,
        sourceURL: URL,
        destinationURL: URL
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: applicationsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw manualInstallError(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                reason: "目标目录不存在或不可用"
            )
        }
        guard FileManager.default.isWritableFile(atPath: applicationsDirectory.path) else {
            throw manualInstallError(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                reason: "目标目录没有写入权限"
            )
        }
    }

    private func manualInstallError(sourceURL: URL, destinationURL: URL, reason: String) -> NSError {
        updateError(
            "\(reason)。请手动打开下载的 App，或将其拖入“应用程序”文件夹；本次未请求管理员权限。已验证的新版本位于：\(sourceURL.path)，目标位置为：\(destinationURL.path)。",
            code: 25
        )
    }

    private func transactionURL(for destination: URL, kind: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: Date())
        let token = String(UUID().uuidString.prefix(8))
        return destination.deletingLastPathComponent().appendingPathComponent(
            "\(destination.lastPathComponent).\(kind)-\(timestamp)-\(token)",
            isDirectory: true
        )
    }

    private func preserveAside(_ url: URL, kind: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let asideURL = transactionURL(for: url, kind: kind)
        do {
            try FileManager.default.moveItem(at: url, to: asideURL)
            logs.append("未就绪的新版已移至 \(asideURL.path)，未覆盖现有 App。")
        } catch {
            logs.append("无法移走未就绪文件 \(url.path)：\(error.localizedDescription)。现有 App 未被删除。")
        }
    }

    private func rollbackAfterLaunchFailure(
        launchError: Error,
        destinationURL: URL,
        backupURL: URL?
    ) -> NSError {
        let fileManager = FileManager.default
        let failedNewURL = transactionURL(for: destinationURL, kind: "failed")

        // The destination name is occupied by the new app, so move the failed new app aside first.
        do {
            try fileManager.moveItem(at: destinationURL, to: failedNewURL)
            logs.append("启动失败的新版已移至：\(failedNewURL.path)")
        } catch {
            let oldDescription = backupURL?.path ?? "没有旧版本"
            return updateError(
                "启动新版本失败（\(launchError.localizedDescription)），且无法移走失败的新版。旧版本仍保留在 \(oldDescription)，请手动处理；不会删除任何 App。",
                code: 26
            )
        }

        guard let backupURL else {
            return updateError(
                "启动新版本失败（\(launchError.localizedDescription)）。未就绪的新版已移至 \(failedNewURL.path)。",
                code: 26
            )
        }

        do {
            try fileManager.moveItem(at: backupURL, to: destinationURL)
            logs.append("启动失败后已回滚，旧版本恢复到：\(destinationURL.path)")
            return updateError(
                "启动新版本失败（\(launchError.localizedDescription)），已回滚到旧版本。失败的新版保留在 \(failedNewURL.path)。",
                code: 26
            )
        } catch {
            return updateError(
                "启动新版本失败（\(launchError.localizedDescription)），自动回滚也失败。旧版本仍保留在 \(backupURL.path)，失败的新版在 \(failedNewURL.path)，请手动处理。",
                code: 26
            )
        }
    }

    private func launchInstalledApp(at url: URL) async throws {
        if let launchApplicationOverride {
            try await launchApplicationOverride(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // The current and updated app have the same Bundle ID; explicitly request the new instance.
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func terminateCurrentApplication() {
        if let terminateApplicationOverride {
            terminateApplicationOverride()
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Check authorization first. A background update check must never present a permission prompt.
    func notifyUserUpdateFound(_ release: ReleaseInfo) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let allowed: Bool
        let reason: String
        switch settings.authorizationStatus {
        case .authorized:
            allowed = true
            reason = "已授权"
        case .provisional:
            allowed = true
            reason = "临时授权"
        case .ephemeral:
            allowed = true
            reason = "本次授权"
        case .notDetermined:
            allowed = false
            reason = "尚未请求通知权限"
        case .denied:
            allowed = false
            reason = "通知权限已关闭"
        @unknown default:
            allowed = false
            reason = "通知权限状态未知"
        }

        guard allowed else {
            logs.append("更新通知未发送：\(reason)。后台检查不会主动请求通知权限，请可在系统设置中开启。")
            return
        }

        let title = "发现更新：\(release.name ?? release.tag_name ?? "新版本")"
        var body = "SmartNote 已发现新版本。"
        if let tag = release.tag_name {
            body += "（\(tag)）"
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "smartnote-update-\(release.id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        do {
            try await center.add(request)
            logs.append("更新通知已发送（通知权限：\(reason)）。")
        } catch {
            logs.append("更新通知发送失败：\(error.localizedDescription)")
        }
    }

    private func updateError(_ message: String, code: Int) -> NSError {
        NSError(
            domain: "UpdateService",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
