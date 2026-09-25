import Foundation
import AppKit
import Combine
import CryptoKit

/// Finds byte-for-byte identical files without ever loading a complete file into memory.
///
/// A SHA-256 digest is only an index: a digest collision is still checked with a
/// streaming byte-for-byte comparison before a group is exposed to the UI.  The
/// scanner also compares file metadata before and after every read, so a file that
/// changes while it is being scanned is reported and excluded from the result.
final class DuplicateScanner: ObservableObject {
    /// 1 MiB keeps the peak read memory bounded while still making large files
    /// efficient.  Hashing and comparison both use this streaming block size.
    static let hashBlockSize = 1024 * 1024

    /// Files are handed to the worker pool in small batches.  The pool never
    /// starts more than two file reads at once.
    private static let batchSize = 32
    private static let maxConcurrentReads = 2
    private static let maximumRecordedIssues = 200

    @Published var isScanning = false
    @Published var duplicates: [DuplicateGroup] = []
    @Published var scanProgress: Double = 0
    @Published var scanIssues: [ScanIssue] = []
    @Published var skippedFileCount = 0
    @Published var wasScanCancelled = false
    @Published var lastCleanupResult: CleanupResult?

    private var scanTask: Task<Void, Never>?

    struct ScanIssue: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let reason: String
    }

    struct DuplicateGroup: Identifiable, Sendable {
        let id = UUID()
        let fileName: String
        /// Sorted by the retention rule: oldest modification date first, then
        /// shortest path, then lexical path order.
        let files: [DuplicateFile]

        /// Keep the oldest file by default.  This is deliberately not based on
        /// the UI state, so every caller uses the same safe retention rule.
        var keptFile: DuplicateFile? {
            files.first
        }

        /// The keep item is structurally excluded; there is no caller-controlled
        /// "keep newest/oldest" switch that could accidentally select it.
        var filesToDelete: [DuplicateFile] {
            guard let keptFile else { return [] }
            return files.filter { $0.id != keptFile.id && $0.url != keptFile.url }
        }

        var totalSize: Int64 {
            files.reduce(0) { $0 + $1.size }
        }

        var reclaimableSize: Int64 {
            filesToDelete.reduce(0) { $0 + $1.size }
        }
    }

    struct DuplicateFile: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let size: Int64
        let modifiedDate: Date
        /// Lowercase hexadecimal SHA-256 digest captured during the scan.
        let hash: String
    }

    struct CleanupIssue: Identifiable, Sendable {
        let id = UUID()
        let url: URL
        let message: String
    }

    /// Result of the pre-cleanup validation.  This method does not call
    /// `trashItem`; it is intentionally useful for a dry run and for tests.
    struct CleanupValidation: Sendable {
        let groupID: UUID
        let keep: DuplicateFile?
        let readyToTrash: [DuplicateFile]
        let skipped: [CleanupIssue]
        let wasCancelled: Bool
    }

    struct CleanupResult: Identifiable, Sendable {
        let id = UUID()
        let groupID: UUID
        let keep: DuplicateFile?
        let movedToTrash: [URL]
        let skipped: [CleanupIssue]
        let failed: [CleanupIssue]

        var hasProblems: Bool {
            !skipped.isEmpty || !failed.isEmpty
        }
    }

    // MARK: - Public operations

    /// Starts a cancellable scan.  The view uses this method so cancellation
    /// refers to the actual task that is doing the work.
    func startScan(
        _ directoryURL: URL,
        extensions: [String] = ["pdf", "doc", "docx", "txt", "md", "ppt", "pptx"]
    ) {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.scanDirectory(directoryURL, extensions: extensions)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Scans a directory in bounded batches.  Only one fingerprint per unique
    /// digest is retained after processing; file contents are never retained.
    func scanDirectory(
        _ directoryURL: URL,
        extensions: [String] = ["pdf", "doc", "docx", "txt", "md", "ppt", "pptx"]
    ) async {
        await MainActor.run {
            isScanning = true
            duplicates = []
            scanProgress = 0
            scanIssues = []
            skippedFileCount = 0
            wasScanCancelled = false
            lastCleanupResult = nil
        }

        let allowedExtensions = Set(extensions.map { $0.lowercased() })
        var issues: [ScanIssue] = []
        var skipped = 0

        do {
            // A first, metadata-only enumeration gives the progress bar a useful
            // total without retaining a potentially huge array of URLs.
            let totalCandidates = try await countCandidates(
                in: directoryURL,
                allowedExtensions: allowedExtensions
            )
            try Task.checkCancellation()

            guard totalCandidates > 0 else {
                await finishScan(groups: [], issues: issues, skipped: skipped, cancelled: false)
                return
            }

            guard let enumerator = makeEnumerator(for: directoryURL) else {
                let issue = ScanIssue(
                    url: directoryURL,
                    reason: "无法打开目录（目录不存在或没有读取权限）"
                )
                issues.append(issue)
                skipped += 1
                await finishScan(groups: [], issues: issues, skipped: skipped, cancelled: false)
                return
            }

            // The dictionary retains metadata for at most one file per unique
            // digest, plus additional files only when a duplicate candidate is
            // actually found.  Contents are never stored here.
            var fingerprintsByDigest: [String: [FileFingerprint]] = [:]
            var batch: [URL] = []
            var processed = 0

            while let element = enumerator.nextObject() {
                try Task.checkCancellation()

                guard let fileURL = element as? URL,
                      allowedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                    continue
                }

                // Do a cheap regular-file check before putting the URL in a
                // batch.  Symbolic links and special files are intentionally
                // skipped rather than followed.
                do {
                    _ = try Self.readMetadata(for: fileURL)
                } catch {
                    recordIssue(
                        ScanIssue(url: fileURL, reason: Self.reason(for: error)),
                        issues: &issues,
                        skipped: &skipped
                    )
                    processed += 1
                    continue
                }

                batch.append(fileURL)
                if batch.count >= Self.batchSize {
                    try Task.checkCancellation()
                    let batchCount = batch.count
                    let results = await fingerprintBatch(batch)
                    appendFingerprints(
                        results,
                        to: &fingerprintsByDigest,
                        issues: &issues,
                        skipped: &skipped
                    )
                    batch.removeAll(keepingCapacity: true)
                    processed += batchCount
                    await updateScanProgress(
                        processed: processed,
                        total: totalCandidates
                    )
                }
            }

            if !batch.isEmpty {
                try Task.checkCancellation()
                let batchCount = batch.count
                let results = await fingerprintBatch(batch)
                appendFingerprints(
                    results,
                    to: &fingerprintsByDigest,
                    issues: &issues,
                    skipped: &skipped
                )
                processed += batchCount
                await updateScanProgress(processed: processed, total: totalCandidates)
                batch.removeAll(keepingCapacity: true)
            }

            try Task.checkCancellation()
            await updateScanProgress(processed: max(processed, totalCandidates), total: totalCandidates)

            let groups = await buildConfirmedGroups(
                from: fingerprintsByDigest,
                issues: &issues,
                skipped: &skipped
            )
            try Task.checkCancellation()
            await finishScan(groups: groups, issues: issues, skipped: skipped, cancelled: false)
        } catch is CancellationError {
            await finishScan(groups: [], issues: issues, skipped: skipped, cancelled: true)
        } catch {
            let issue = ScanIssue(url: directoryURL, reason: Self.reason(for: error))
            recordIssue(issue, issues: &issues, skipped: &skipped)
            await finishScan(groups: [], issues: issues, skipped: skipped, cancelled: false)
        }
    }

    /// Re-checks the keep file and every candidate immediately before cleanup.
    /// This method performs no deletion and is therefore safe to call from a
    /// preview or a sandbox probe.
    func validateCleanup(in group: DuplicateGroup) async -> CleanupValidation {
        guard let keep = group.keptFile else {
            return CleanupValidation(
                groupID: group.id,
                keep: nil,
                readyToTrash: [],
                skipped: [],
                wasCancelled: false
            )
        }

        var skipped: [CleanupIssue] = []

        // The keep file is part of the safety check too.  If it changed, the
        // group is stale and no candidate may be moved to the Trash.
        switch await Self.verifyFingerprint(keep) {
        case .verified:
            break
        case .changed(let reason):
            for file in group.filesToDelete {
                skipped.append(
                    CleanupIssue(
                        url: file.url,
                        message: "保留项在扫描后发生变化（\(reason)），本组未清理"
                    )
                )
            }
            return CleanupValidation(
                groupID: group.id,
                keep: keep,
                readyToTrash: [],
                skipped: skipped,
                wasCancelled: Task.isCancelled
            )
        case .unreadable(let reason):
            for file in group.filesToDelete {
                skipped.append(
                    CleanupIssue(
                        url: file.url,
                        message: "无法再次读取保留项（\(reason)），本组未清理"
                    )
                )
            }
            return CleanupValidation(
                groupID: group.id,
                keep: keep,
                readyToTrash: [],
                skipped: skipped,
                wasCancelled: Task.isCancelled
            )
        case .different:
            return CleanupValidation(
                groupID: group.id,
                keep: keep,
                readyToTrash: [],
                skipped: group.filesToDelete.map {
                    CleanupIssue(url: $0.url, message: "保留项内容确认失败，本组未清理")
                },
                wasCancelled: false
            )
        case .cancelled:
            return CleanupValidation(
                groupID: group.id,
                keep: keep,
                readyToTrash: [],
                skipped: group.filesToDelete.map {
                    CleanupIssue(url: $0.url, message: "扫描/清理已取消")
                },
                wasCancelled: true
            )
        }

        var ready: [DuplicateFile] = []
        for file in group.filesToDelete {
            if Task.isCancelled {
                skipped.append(CleanupIssue(url: file.url, message: "扫描/清理已取消"))
                continue
            }

            switch await Self.verifyPair(keep, file) {
            case .verified:
                ready.append(file)
            case .changed(let reason):
                skipped.append(CleanupIssue(url: file.url, message: "文件已变化，已跳过：\(reason)"))
            case .different:
                skipped.append(CleanupIssue(url: file.url, message: "内容与保留项不同，已跳过"))
            case .unreadable(let reason):
                skipped.append(CleanupIssue(url: file.url, message: "无法再次读取文件，已跳过：\(reason)"))
            case .cancelled:
                skipped.append(CleanupIssue(url: file.url, message: "扫描/清理已取消"))
            }
        }

        return CleanupValidation(
            groupID: group.id,
            keep: keep,
            readyToTrash: ready,
            skipped: skipped,
            wasCancelled: Task.isCancelled
        )
    }

    /// Cleans one group only.  There is intentionally no all-groups method.
    /// The UI must obtain this result from a per-group confirmation sheet.
    @discardableResult
    func cleanupGroup(_ group: DuplicateGroup) async -> CleanupResult {
        let validation = await validateCleanup(in: group)
        var moved: [URL] = []
        var skipped = validation.skipped
        var failed: [CleanupIssue] = []

        if !validation.wasCancelled, !Task.isCancelled, let keep = validation.keep {
            for file in validation.readyToTrash {
                // Defense in depth: even if a stale result is passed in, the
                // retained item can never reach the destructive branch.
                guard file.id != keep.id, file.url != keep.url else {
                    skipped.append(CleanupIssue(url: file.url, message: "保留项不会移入废纸篓"))
                    continue
                }

                if Task.isCancelled {
                    skipped.append(CleanupIssue(url: file.url, message: "扫描/清理已取消"))
                    continue
                }

                // Recheck immediately before the destructive operation as well
                // as during the all-candidate validation pass above.  This
                // catches a replacement between confirmation and execution.
                switch await Self.verifyPair(keep, file) {
                case .verified:
                    do {
                        try FileManager.default.trashItem(
                            at: file.url,
                            resultingItemURL: nil
                        )
                        moved.append(file.url)
                    } catch {
                        let message = "移入废纸篓失败：\(Self.reason(for: error))"
                        failed.append(CleanupIssue(url: file.url, message: message))
                    }
                case .changed(let reason):
                    skipped.append(CleanupIssue(url: file.url, message: "执行前文件已变化，已跳过：\(reason)"))
                case .different:
                    skipped.append(CleanupIssue(url: file.url, message: "执行前内容不同，已跳过"))
                case .unreadable(let reason):
                    skipped.append(CleanupIssue(url: file.url, message: "执行前无法读取，已跳过：\(reason)"))
                case .cancelled:
                    skipped.append(CleanupIssue(url: file.url, message: "扫描/清理已取消"))
                }
            }
        }

        let result = CleanupResult(
            groupID: group.id,
            keep: validation.keep,
            movedToTrash: moved,
            skipped: skipped,
            failed: failed
        )

        await MainActor.run {
            lastCleanupResult = result
            // The result contains every skipped/failed URL, so remove the stale
            // card and make the user rescan rather than offering another unsafe
            // attempt against old metadata.
            duplicates.removeAll { $0.id == group.id }
        }
        return result
    }

    // MARK: - Scanning implementation

    private func makeEnumerator(for directoryURL: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
    }

    private func countCandidates(
        in directoryURL: URL,
        allowedExtensions: Set<String>
    ) async throws -> Int {
        guard let enumerator = makeEnumerator(for: directoryURL) else {
            throw ScanFailure.cannotOpenDirectory
        }

        var count = 0
        while let element = enumerator.nextObject() {
            try Task.checkCancellation()
            guard let url = element as? URL,
                  allowedExtensions.contains(url.pathExtension.lowercased()) else {
                continue
            }
            // Count matching names even when metadata cannot be read.  The
            // actual pass will record the specific permission/symlink error;
            // counting it here keeps progress and skip reporting accurate.
            count += 1
            _ = try? Self.readMetadata(for: url)
        }
        return count
    }

    private func fingerprintBatch(_ urls: [URL]) async -> [FingerprintOutcome] {
        var outcomes: [FingerprintOutcome] = []
        let initialCount = min(Self.maxConcurrentReads, urls.count)
        var nextIndex = 0

        await withTaskGroup(of: FingerprintOutcome.self) { group in
            while nextIndex < initialCount {
                let url = urls[nextIndex]
                group.addTask {
                    await Self.fingerprint(url)
                }
                nextIndex += 1
            }

            while let outcome = await group.next() {
                outcomes.append(outcome)
                if !Task.isCancelled, nextIndex < urls.count {
                    let url = urls[nextIndex]
                    group.addTask {
                        await Self.fingerprint(url)
                    }
                    nextIndex += 1
                }
            }
        }
        return outcomes
    }

    private func appendFingerprints(
        _ outcomes: [FingerprintOutcome],
        to buckets: inout [String: [FileFingerprint]],
        issues: inout [ScanIssue],
        skipped: inout Int
    ) {
        for outcome in outcomes {
            switch outcome {
            case .success(let fingerprint):
                // A digest (and size) is an index, not proof.  Keeping all
                // members of a colliding bucket lets the later byte compare
                // make the final decision safely.
                buckets[fingerprint.bucketKey, default: []].append(fingerprint)
            case .failure(let url, let reason):
                recordIssue(
                    ScanIssue(url: url, reason: reason),
                    issues: &issues,
                    skipped: &skipped
                )
            case .cancelled:
                continue
            }
        }
    }

    private func buildConfirmedGroups(
        from buckets: [String: [FileFingerprint]],
        issues: inout [ScanIssue],
        skipped: inout Int
    ) async -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []

        for bucket in buckets.values where bucket.count > 1 {
            if Task.isCancelled { return [] }

            let sorted = bucket.sorted(by: Self.isBeforeRetentionOrder)
            var keeper: FileFingerprint?
            var confirmed: [FileFingerprint] = []

            for candidate in sorted {
                if Task.isCancelled { return [] }

                guard let currentKeeper = keeper else {
                    switch await Self.verifyFingerprint(candidate) {
                    case .verified:
                        keeper = candidate
                        confirmed = [candidate]
                    case .changed(let reason):
                        recordIssue(
                            ScanIssue(url: candidate.url, reason: "文件在扫描期间发生变化，已跳过：\(reason)"),
                            issues: &issues,
                            skipped: &skipped
                        )
                    case .different:
                        recordIssue(
                            ScanIssue(url: candidate.url, reason: "文件内容确认失败，已跳过"),
                            issues: &issues,
                            skipped: &skipped
                        )
                    case .unreadable(let reason):
                        recordIssue(
                            ScanIssue(url: candidate.url, reason: "无法再次读取，已跳过：\(reason)"),
                            issues: &issues,
                            skipped: &skipped
                        )
                    case .cancelled:
                        return []
                    }
                    continue
                }

                // This is the required final confirmation.  The SHA-256 values
                // are checked again while both files are compared byte-for-byte
                // in bounded chunks.
                switch await Self.verifyPair(currentKeeper, candidate) {
                case .verified:
                    confirmed.append(candidate)
                case .changed(let reason):
                    recordIssue(
                        ScanIssue(url: candidate.url, reason: "文件在扫描期间发生变化，已跳过：\(reason)"),
                        issues: &issues,
                        skipped: &skipped
                    )
                case .different:
                    recordIssue(
                        ScanIssue(
                            url: candidate.url,
                            reason: "摘要相同但内容不同（可能是极小概率碰撞或扫描期间变化），已跳过"
                        ),
                        issues: &issues,
                        skipped: &skipped
                    )
                case .unreadable(let reason):
                    recordIssue(
                        ScanIssue(url: candidate.url, reason: "无法进行内容确认，已跳过：\(reason)"),
                        issues: &issues,
                        skipped: &skipped
                    )
                case .cancelled:
                    return []
                }
            }

            guard confirmed.count > 1, let keep = confirmed.first else { continue }
            let duplicateFiles = confirmed.map {
                DuplicateFile(
                    url: $0.url,
                    size: $0.size,
                    modifiedDate: $0.modifiedDate,
                    hash: $0.hash
                )
            }
            groups.append(
                DuplicateGroup(
                    fileName: keep.url.lastPathComponent,
                    files: duplicateFiles
                )
            )
        }

        groups.sort {
            if $0.totalSize != $1.totalSize { return $0.totalSize > $1.totalSize }
            return $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
        }
        return groups
    }

    private func updateScanProgress(processed: Int, total: Int) async {
        let progress: Double
        if total <= 0 {
            progress = 1
        } else {
            progress = min(1, max(0, Double(processed) / Double(total)))
        }
        await MainActor.run {
            scanProgress = progress
        }
    }

    private func finishScan(
        groups: [DuplicateGroup],
        issues: [ScanIssue],
        skipped: Int,
        cancelled: Bool
    ) async {
        await MainActor.run {
            duplicates = cancelled ? [] : groups
            scanProgress = cancelled ? scanProgress : 1
            scanIssues = Array(issues.prefix(Self.maximumRecordedIssues))
            skippedFileCount = skipped
            wasScanCancelled = cancelled
            isScanning = false
        }
    }

    private func recordIssue(
        _ issue: ScanIssue,
        issues: inout [ScanIssue],
        skipped: inout Int
    ) {
        skipped += 1
        if issues.count < Self.maximumRecordedIssues {
            issues.append(issue)
        }
    }

    // MARK: - Streaming hash and comparison

    private struct FileMetadata: Equatable, Sendable {
        let size: Int64
        let modifiedDate: Date

        static func == (lhs: FileMetadata, rhs: FileMetadata) -> Bool {
            lhs.size == rhs.size && lhs.modifiedDate == rhs.modifiedDate
        }
    }

    private struct FileFingerprint: Sendable {
        let url: URL
        let size: Int64
        let modifiedDate: Date
        let hash: String

        var bucketKey: String {
            // Length is included as a cheap guard before the byte comparison.
            "\(hash)-\(size)"
        }
    }

    private struct FingerprintValues: Sendable {
        let url: URL
        let size: Int64
        let modifiedDate: Date
        let hash: String

        init(url: URL, size: Int64, modifiedDate: Date, hash: String) {
            self.url = url
            self.size = size
            self.modifiedDate = modifiedDate
            self.hash = hash
        }

        init(_ file: DuplicateFile) {
            self.init(
                url: file.url,
                size: file.size,
                modifiedDate: file.modifiedDate,
                hash: file.hash
            )
        }

        init(_ fingerprint: FileFingerprint) {
            self.init(
                url: fingerprint.url,
                size: fingerprint.size,
                modifiedDate: fingerprint.modifiedDate,
                hash: fingerprint.hash
            )
        }
    }

    private enum FingerprintOutcome: Sendable {
        case success(FileFingerprint)
        case failure(URL, String)
        case cancelled
    }

    private enum VerificationResult: Sendable {
        case verified
        case changed(String)
        case different
        case unreadable(String)
        case cancelled
    }

    private enum ScanFailure: LocalizedError, Sendable {
        case cannotOpenDirectory
        case notRegularFile
        case fileChanged
        case sizeChanged
        case hashChanged
        case contentDifferent

        var errorDescription: String? {
            switch self {
            case .cannotOpenDirectory:
                return "无法打开目录"
            case .notRegularFile:
                return "不是普通文件（可能是符号链接或特殊文件）"
            case .fileChanged:
                return "文件在读取前后发生变化"
            case .sizeChanged:
                return "文件大小在读取前后发生变化"
            case .hashChanged:
                return "文件内容摘要已变化"
            case .contentDifferent:
                return "文件内容不同"
            }
        }
    }

    private static func readMetadata(for url: URL) throws -> FileMetadata {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular else {
            throw ScanFailure.notRegularFile
        }
        guard let number = attributes[.size] as? NSNumber else {
            throw ScanFailure.notRegularFile
        }
        let date = attributes[.modificationDate] as? Date ?? Date.distantPast
        return FileMetadata(size: number.int64Value, modifiedDate: date)
    }

    private static func fingerprint(_ url: URL) async -> FingerprintOutcome {
        do {
            let before = try readMetadata(for: url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            var bytesRead: Int64 = 0

            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: hashBlockSize),
                      !chunk.isEmpty else {
                    break
                }
                // The chunk is released on the next iteration; no complete
                // file Data is ever created.
                hasher.update(data: chunk)
                bytesRead += Int64(chunk.count)
                await Task.yield()
            }

            try Task.checkCancellation()
            let after = try readMetadata(for: url)
            guard before == after else { throw ScanFailure.fileChanged }
            guard bytesRead == after.size else { throw ScanFailure.sizeChanged }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return .success(
                FileFingerprint(
                    url: url,
                    size: after.size,
                    modifiedDate: after.modifiedDate,
                    hash: digest
                )
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(url, reason(for: error))
        }
    }

    private static func verifyFingerprint(_ fingerprint: DuplicateFile) async -> VerificationResult {
        await verifyFingerprint(FingerprintValues(fingerprint))
    }

    private static func verifyFingerprint(_ fingerprint: FileFingerprint) async -> VerificationResult {
        await verifyFingerprint(FingerprintValues(fingerprint))
    }

    private static func verifyFingerprint(_ values: FingerprintValues) async -> VerificationResult {
        do {
            let before = try readMetadata(for: values.url)
            let expectedMetadata = FileMetadata(
                size: values.size,
                modifiedDate: values.modifiedDate
            )
            guard before == expectedMetadata else {
                return .changed("大小或修改时间与扫描时不同")
            }

            let handle = try FileHandle(forReadingFrom: values.url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var bytesRead: Int64 = 0

            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: hashBlockSize),
                      !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
                bytesRead += Int64(chunk.count)
                await Task.yield()
            }

            try Task.checkCancellation()
            let after = try readMetadata(for: values.url)
            guard before == after else { return .changed("文件在确认期间发生变化") }
            guard bytesRead == after.size else { return .changed("文件大小已变化") }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == values.hash else { return .changed("SHA-256 摘要已变化") }
            return .verified
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unreadable(reason(for: error))
        }
    }

    /// Reads two files in lockstep and compares every byte while recomputing
    /// both SHA-256 digests.  Thus this is both the collision check and the
    /// scan-time mutation check; peak read memory is 2 * hashBlockSize.
    private static func verifyPair(
        _ left: DuplicateFile,
        _ right: DuplicateFile
    ) async -> VerificationResult {
        await verifyPair(FingerprintValues(left), FingerprintValues(right))
    }

    private static func verifyPair(
        _ left: FileFingerprint,
        _ right: FileFingerprint
    ) async -> VerificationResult {
        await verifyPair(FingerprintValues(left), FingerprintValues(right))
    }

    private static func verifyPair(
        _ left: FingerprintValues,
        _ right: FingerprintValues
    ) async -> VerificationResult {
        do {
            let leftBefore = try readMetadata(for: left.url)
            let rightBefore = try readMetadata(for: right.url)
            let leftExpected = FileMetadata(size: left.size, modifiedDate: left.modifiedDate)
            let rightExpected = FileMetadata(size: right.size, modifiedDate: right.modifiedDate)
            guard leftBefore == leftExpected else { return .changed("左侧文件大小或修改时间已变化") }
            guard rightBefore == rightExpected else { return .changed("右侧文件大小或修改时间已变化") }

            let leftHandle = try FileHandle(forReadingFrom: left.url)
            defer { try? leftHandle.close() }
            let rightHandle = try FileHandle(forReadingFrom: right.url)
            defer { try? rightHandle.close() }

            var leftHasher = SHA256()
            var rightHasher = SHA256()
            var leftBytes: Int64 = 0
            var rightBytes: Int64 = 0

            while true {
                try Task.checkCancellation()
                let leftChunk = try leftHandle.read(upToCount: hashBlockSize) ?? Data()
                let rightChunk = try rightHandle.read(upToCount: hashBlockSize) ?? Data()
                if leftChunk != rightChunk {
                    return .different
                }
                if leftChunk.isEmpty {
                    break
                }
                leftHasher.update(data: leftChunk)
                rightHasher.update(data: rightChunk)
                leftBytes += Int64(leftChunk.count)
                rightBytes += Int64(rightChunk.count)
                await Task.yield()
            }

            try Task.checkCancellation()
            let leftAfter = try readMetadata(for: left.url)
            let rightAfter = try readMetadata(for: right.url)
            guard leftBefore == leftAfter, rightBefore == rightAfter else {
                return .changed("文件在内容确认期间发生变化")
            }
            guard leftBytes == leftAfter.size, rightBytes == rightAfter.size else {
                return .changed("文件大小在内容确认期间发生变化")
            }
            let leftDigest = leftHasher.finalize().map { String(format: "%02x", $0) }.joined()
            let rightDigest = rightHasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard leftDigest == left.hash else { return .changed("左侧 SHA-256 摘要已变化") }
            guard rightDigest == right.hash else { return .changed("右侧 SHA-256 摘要已变化") }
            return .verified
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .unreadable(reason(for: error))
        }
    }

    private static func isBeforeRetentionOrder(
        _ lhs: FileFingerprint,
        _ rhs: FileFingerprint
    ) -> Bool {
        // Retention policy: keep the earliest modified file.  If timestamps
        // are equal, keep the shortest path; lexical order is the deterministic
        // final tie-breaker.  All other files are the only cleanup candidates.
        if lhs.modifiedDate != rhs.modifiedDate {
            return lhs.modifiedDate < rhs.modifiedDate
        }
        if lhs.url.path.count != rhs.url.path.count {
            return lhs.url.path.count < rhs.url.path.count
        }
        return lhs.url.path < rhs.url.path
    }

    private static func reason(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
