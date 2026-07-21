import Foundation
import SwiftUI
import AppKit

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

    var owner: String
    var repo: String

    @Published var latestCheckedRelease: ReleaseInfo?
    @Published var lastError: String?
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double? = nil // 0.0 - 1.0
    @Published var logs: [String] = []
    @Published var lastInstalledURL: URL? = nil

    var currentAppVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    init(owner: String = "XiJian-Development-Group", repo: String = "SmartNote") {
        self.owner = owner
        self.repo = repo
    }

    func isUpdateAvailable(_ release: ReleaseInfo) -> Bool {
        guard let tag = release.tag_name else { return false }
        let releaseVersion = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let currentVersion = currentAppVersion
        guard !releaseVersion.isEmpty else { return false }
        let releaseComponents = releaseVersion.split(separator: ".").compactMap { Int($0) }
        let currentComponents = currentVersion.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(releaseComponents.count, currentComponents.count) {
            let r = i < releaseComponents.count ? releaseComponents[i] : 0
            let c = i < currentComponents.count ? currentComponents[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    /// Update the target repository used for checks/downloads.
    func updateRepository(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    /// Download the first zip asset from the release, unzip and attempt installation (copy to /Applications).
    /// Returns the installed app URL if installation succeeded, or the unzip folder if not installed.
    func performDownloadAndInstall(release: ReleaseInfo, autoInstall: Bool = true) async throws -> URL? {
        guard let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) ?? release.assets.first else {
            throw NSError(domain: "UpdateService", code: 0, userInfo: [NSLocalizedDescriptionKey: "No assets found in release"]) }

        guard let assetURL = URL(string: asset.browser_download_url) else {
            throw URLError(.badURL)
        }

        logs.append("开始下载：\(assetURL.absoluteString)")
        isDownloading = true
        downloadProgress = 0.0
        defer {
            isDownloading = false
            downloadProgress = nil
        }

        let downloaded = try await downloadAsset(assetURL) { [weak self] progress in
            // Keep this progress handler synchronous; dispatch to the main actor from here
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        logs.append("下载完成，开始解压：\(downloaded.path)")
        let unzipped = try unzip(at: downloaded)
        logs.append("解压完成：\(unzipped.path)")

        if autoInstall {
            do {
                if let installed = try installUnzippedApp(at: unzipped) {
                    logs.append("安装成功：\(installed.path)")
                    lastInstalledURL = installed
                    return installed
                } else {
                    logs.append("未找到 .app 可安装（仅解压）：\(unzipped.path)")
                    return unzipped
                }
            } catch {
                logs.append("安装失败：\(error.localizedDescription)")
                // rethrow for UI to handle; keep the unzipped folder for manual install
                throw error
            }
        } else {
            return unzipped
        }
    }

    func checkForUpdate(channel: Channel) async throws -> ReleaseInfo? {
        lastError = nil
        let session = URLSession.shared
        if channel == .latest {
            let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            let release = try decoder.decode(ReleaseInfo.self, from: data)
            latestCheckedRelease = release
            return release
        } else {
            let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases")!
            let (data, resp) = try await session.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            let releases = try decoder.decode([ReleaseInfo].self, from: data)
            let prereleases = releases.filter { $0.prerelease }
            let sorted = prereleases.sorted { ($0.published_at ?? "") > ($1.published_at ?? "") }
            let release = sorted.first
            latestCheckedRelease = release
            return release
        }
    }

    func downloadAsset(_ assetURL: URL, progress: ((Double)->Void)? = nil) async throws -> URL {
        // Use URLSession with delegate to report progress
        let destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SmartNoteUpdates", isDirectory: true)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let tempFile = destDir.appendingPathComponent(assetURL.lastPathComponent)

        final class DLDelegate: NSObject, URLSessionDownloadDelegate {
            let progressHandler: ((Double) -> Void)?
            let completion: (Result<URL, Error>) -> Void

            init(progress: ((Double)->Void)?, completion: @escaping (Result<URL, Error>) -> Void) {
                self.progressHandler = progress
                self.completion = completion
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
                guard totalBytesExpectedToWrite > 0 else { return }
                let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                // Report progress on the main actor so UI updates are safe.
                DispatchQueue.main.async {
                    self.progressHandler?(p)
                }
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
                // report the temporary location to completion; caller will move it
                completion(.success(location))
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                if let error = error {
                    completion(.failure(error))
                }
            }
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let delegate = DLDelegate(progress: progress) { result in
                switch result {
                case .success(let tmp):
                    // move downloaded file from tmp to dest
                    do {
                        // tmp is a file URL; move to tempFile
                        try? FileManager.default.removeItem(at: tempFile)
                        try FileManager.default.moveItem(at: tmp, to: tempFile)
                        continuation.resume(returning: tempFile)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case .failure(let err):
                    continuation.resume(throwing: err)
                }
            }

            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            let task = session.downloadTask(with: assetURL)
            task.resume()
        }
    }

    func unzip(at zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let dest = zipURL.deletingPathExtension()
        try? fm.removeItem(at: dest)

        // Use system unzip for simplicity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipURL.path, "-d", dest.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "UpdateService", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "unzip failed"])
        }
        return dest
    }

    func installUnzippedApp(at folderURL: URL) throws -> URL? {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        if let appURL = contents.first(where: { $0.pathExtension == "app" }) {
            let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
            let dest = applications.appendingPathComponent(appURL.lastPathComponent)
            // try to replace
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            do {
                try fm.copyItem(at: appURL, to: dest)
                return dest
            } catch {
                // fallback: try move
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: appURL, to: dest)
                return dest
            }
        }
        return nil
    }

    /// Attempt to launch the installed app and terminate current app.
    func installAndRelaunchApp(at installedURL: URL) throws {
        // Ensure file exists
        guard FileManager.default.fileExists(atPath: installedURL.path) else {
            throw NSError(domain: "UpdateService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Installed app not found"]) }

        // Try to open the new app
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: installedURL, configuration: configuration) { app, error in
            if let err = error {
                Task { @MainActor [weak self] in
                    self?.logs.append("打开新应用失败：\(err.localizedDescription)")
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.logs.append("已启动新应用：\(installedURL.path)")
                }
                // terminate current app shortly after launching the new one
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    // Termination must be executed on the main actor
                    Task { @MainActor in
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// Send a local notification to notify the user that an update was found.
    func notifyUserUpdateFound(_ release: ReleaseInfo) async {
        let title = "发现更新: \(release.name ?? release.tag_name ?? "新版本")"
        var body = "在 GitHub Release 中检测到新版本。"
        if let tag = release.tag_name {
            body += " (\(tag))"
        }
        _ = await NotificationService.shared.requestAuthorization()
        await NotificationService.shared.sendImmediateTodoNotification(title: title, body: body)
    }
}
