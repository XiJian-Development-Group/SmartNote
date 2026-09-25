import SwiftUI
import UniformTypeIdentifiers

struct DuplicateScannerView: View {
    @StateObject private var scanner = DuplicateScanner()
    @State private var showDirectoryPicker = false
    @State private var pendingGroup: DuplicateScanner.DuplicateGroup?
    @State private var isCleaning = false
    @State private var cleanupResult: DuplicateScanner.CleanupResult?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if scanner.isScanning {
                scanningView
            } else if scanner.duplicates.isEmpty {
                emptyStateView
            } else {
                resultsView
            }
        }
        .fileImporter(
            isPresented: $showDirectoryPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleDirectorySelection(result)
        }
        .sheet(item: $pendingGroup) { group in
            CleanupConfirmationView(
                group: group,
                isCleaning: isCleaning,
                onConfirm: {
                    isCleaning = true
                    Task { @MainActor in
                        let result = await scanner.cleanupGroup(group)
                        isCleaning = false
                        cleanupResult = result
                        pendingGroup = nil
                    }
                },
                onCancel: {
                    pendingGroup = nil
                }
            )
        }
        .alert(item: $cleanupResult) { result in
            Alert(
                title: Text(cleanupTitle(for: result)),
                message: Text(cleanupMessage(for: result)),
                dismissButton: .default(Text("好"))
            )
        }
        .onDisappear {
            scanner.cancelScan()
        }
    }

    private var headerView: some View {
        HStack {
            Text("重复文件清理")
                .font(.title2)
                .fontWeight(.bold)

            Spacer()

            Button {
                showDirectoryPicker = true
            } label: {
                Label("选择文件夹", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .disabled(scanner.isScanning || isCleaning)
        }
        .padding()
    }

    private var scanningView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: scanner.scanProgress)
                .progressViewStyle(.linear)
                .frame(width: 320)

            Text("正在扫描… \(Int(scanner.scanProgress * 100))%")
                .foregroundStyle(.secondary)

            if scanner.skippedFileCount > 0 {
                Text("已跳过 \(scanner.skippedFileCount) 个无法安全读取或发生变化的文件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("取消扫描", role: .cancel) {
                scanner.cancelScan()
            }
            .buttonStyle(.bordered)
            .disabled(!scanner.isScanning)

            Spacer()
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.on.doc")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            if scanner.wasScanCancelled {
                Text("扫描已取消")
                    .font(.headline)
            } else if scanner.skippedFileCount > 0 {
                Text("没有可确认的重复文件")
                    .font(.headline)
                Text("已跳过 \(scanner.skippedFileCount) 个文件；详情见扫描结果中的跳过提示")
                    .foregroundStyle(.secondary)
            } else {
                Text("点击上方按钮选择要扫描的文件夹")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Text("支持 PDF、DOC、DOCX、TXT、MD、PPT、PPTX")
                .font(.caption)
                .foregroundStyle(.secondary)

            scanIssuesView

            Spacer()
        }
    }

    private var resultsView: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("发现 \(scanner.duplicates.count) 组重复文件")
                    .font(.headline)

                Spacer()

                if scanner.skippedFileCount > 0 {
                    Text("跳过 \(scanner.skippedFileCount) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 4) {
                Text("保留规则：优先保留最早修改的文件；修改时间相同则保留路径最短的文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("每个分组都需要单独确认；清理会将文件移入废纸篓，可从废纸篓恢复。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            scanIssuesView
                .padding(.horizontal)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(scanner.duplicates) { group in
                        DuplicateGroupCard(
                            group: group,
                            onReview: {
                                pendingGroup = group
                            }
                        )
                    }
                }
                .padding()
            }
        }
    }

    private var scanIssuesView: some View {
        Group {
            if !scanner.scanIssues.isEmpty {
                DisclosureGroup("查看跳过/变化文件（已记录 \(scanner.skippedFileCount) 个）") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(scanner.scanIssues) { issue in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.url.lastPathComponent)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Text(issue.reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
    }

    private func handleDirectorySelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                scanner.startScan(url)
            }
        case .failure(let error):
            print("Error selecting directory: \(error)")
        }
    }

    private func cleanupTitle(for result: DuplicateScanner.CleanupResult) -> String {
        if result.failed.isEmpty && result.skipped.isEmpty {
            return "清理完成"
        }
        return "清理完成，但有文件未处理"
    }

    private func cleanupMessage(for result: DuplicateScanner.CleanupResult) -> String {
        var lines: [String] = []
        lines.append("已移入废纸篓：\(result.movedToTrash.count) 个，可从废纸篓恢复。")

        if !result.skipped.isEmpty {
            lines.append("已跳过：\(result.skipped.count) 个（文件已变化、内容不同或无法读取）。")
        }
        if !result.failed.isEmpty {
            lines.append("失败：\(result.failed.count) 个（权限不足或文件被占用）。")
        }

        let problems = result.skipped + result.failed
        if let first = problems.first {
            lines.append("示例：\(first.url.lastPathComponent) — \(first.message)")
        }
        return lines.joined(separator: "\n")
    }
}

struct DuplicateGroupCard: View {
    let group: DuplicateScanner.DuplicateGroup
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.fileName)
                        .font(.headline)
                    Text("\(group.files.count) 个文件 • 可释放 \(formattedSize(group.reclaimableSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(formattedSize(group.totalSize))
                    .foregroundStyle(.secondary)

                Button {
                    onReview()
                } label: {
                    Label("查看并清理", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            ForEach(group.files) { file in
                HStack {
                    Image(systemName: isKept(file) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isKept(file) ? .green : .gray)

                    VStack(alignment: .leading) {
                        Text(file.url.lastPathComponent)
                            .font(.subheadline)
                        Text("\(formattedSize(file.size)) • \(formattedDate(file.modifiedDate))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(isKept(file) ? "保留" : "确认后移入废纸篓")
                        .font(.caption)
                        .foregroundStyle(isKept(file) ? .green : .red)
                }
                .padding(.leading, 20)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func isKept(_ file: DuplicateScanner.DuplicateFile) -> Bool {
        file.id == group.keptFile?.id
    }
}

struct CleanupConfirmationView: View {
    let group: DuplicateScanner.DuplicateGroup
    let isCleaning: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认清理这一组")
                .font(.title2)
                .fontWeight(.bold)

            Text("本组共有 \(group.files.count) 个文件。")
                .foregroundStyle(.secondary)

            if let keep = group.keptFile {
                Label("保留：\(keep.url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("将移入废纸篓：\(group.filesToDelete.count) 个文件，共 \(formattedSize(group.reclaimableSize))")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("将移入废纸篓，可从废纸篓恢复。执行前会再次校验文件摘要，内容已变化的文件会被跳过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !group.filesToDelete.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.filesToDelete) { file in
                            HStack {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                                Text(file.url.path)
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer()
                                Text(formattedSize(file.size))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
            }

            HStack {
                Button("取消", role: .cancel) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCleaning)

                Spacer()

                Button {
                    onConfirm()
                } label: {
                    if isCleaning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("移入废纸篓", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isCleaning || group.filesToDelete.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .interactiveDismissDisabled(isCleaning)
    }
}

private func formattedSize(_ size: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: size)
}

private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}
