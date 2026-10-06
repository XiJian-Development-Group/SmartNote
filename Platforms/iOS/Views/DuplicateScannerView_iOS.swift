import SwiftUI
import UniformTypeIdentifiers

/// iOS 重复文件清理界面。
///
/// 扫描与清理逻辑由 Shared 的 `DuplicateScanner` 提供（按内容 SHA-256 分组，
/// 并按“保留最早修改的文件”这一固定规则决定去留）。
/// 本视图只负责选择目录、展示分组与确认清理。
struct DuplicateScannerView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var scanner = DuplicateScanner()
    @State private var isPickingDirectory = false
    @State private var selectedDirectory: URL?
    @State private var expandedGroups: Set<UUID> = []
    @State private var cleanupMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    isPickingDirectory = true
                } label: {
                    Label(
                        selectedDirectory?.lastPathComponent ?? "选择资料目录",
                        systemImage: "folder"
                    )
                }

                if scanner.isScanning {
                    ProgressView(value: scanner.scanProgress) {
                        Text("正在扫描…")
                    }
                } else if scanner.isScanning == false && !scanner.duplicates.isEmpty {
                    Text("已跳过 \(scanner.skippedFileCount) 个无法读取的文件")
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }
            } header: {
                Text("目录")
            } footer: {
                Text("按文件内容哈希分组。清理时保留修改时间最早的一份，其余移入废纸篓。")
            }

            if !scanner.scanIssues.isEmpty {
                Section("无法读取") {
                    ForEach(scanner.scanIssues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.url.lastPathComponent)
                                .font(.caption)
                            Text(issue.reason)
                                .font(.caption2)
                                .foregroundStyle(appTheme.secondaryText)
                        }
                    }
                }
            }

            if !scanner.duplicates.isEmpty {
                Section("重复分组（\(scanner.duplicates.count)）") {
                    ForEach(scanner.duplicates) { group in
                        DuplicateGroupRow_iOS(
                            group: group,
                            isExpanded: expandedGroups.contains(group.id),
                            onToggle: { toggle(group.id) },
                            onCleanUp: { cleanUp(group) }
                        )
                    }
                }
            } else if !scanner.isScanning {
                Section {
                    ContentUnavailableView {
                        Label("没有找到重复文件", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("重复清理")
        .fileImporter(
            isPresented: $isPickingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                selectedDirectory = url
                scanner.startScan(url)
            case .failure(let error):
                appState.errorMessage = "选择目录失败：\(error.localizedDescription)"
                appState.showError = true
            }
        }
        .alert("清理结果", isPresented: Binding(
            get: { cleanupMessage != nil },
            set: { if !$0 { cleanupMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(cleanupMessage ?? "")
        }
    }

    private func toggle(_ id: UUID) {
        if expandedGroups.contains(id) {
            expandedGroups.remove(id)
        } else {
            expandedGroups.insert(id)
        }
    }

    /// 清理一组重复文件，并把结果转成一句人话。
    private func cleanUp(_ group: DuplicateScanner.DuplicateGroup) {
        Task {
            let result = await scanner.cleanupGroup(group)
            let reclaimed = Self.sizeText(group.reclaimableSize)
            if result.hasProblems {
                cleanupMessage = "已移入废纸篓 \(result.movedToTrash.count) 个文件"
                    + "（可回收 \(reclaimed)），另有 \(result.skipped.count + result.failed.count) 项未处理成功。"
                appState.hapticFeedbackService.warning()
            } else {
                cleanupMessage = "已移入废纸篓 \(result.movedToTrash.count) 个文件，可回收 \(reclaimed)。"
                appState.hapticFeedbackService.success()
            }
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct DuplicateGroupRow_iOS: View {
    @Environment(\.appTheme) private var appTheme

    let group: DuplicateScanner.DuplicateGroup
    let isExpanded: Bool
    let onToggle: () -> Void
    let onCleanUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.fileName)
                            .font(.headline)
                            .foregroundStyle(appTheme.primaryText)
                        Text("\(group.files.count) 个相同文件 · 共 \(Self.sizeText(group.totalSize))")
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(appTheme.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(group.files) { file in
                    HStack {
                        Image(systemName: file.id == group.keptFile?.id ? "star.fill" : "doc")
                            .foregroundStyle(file.id == group.keptFile?.id ? appTheme.accent : appTheme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.url.lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(file.modifiedDate, format: .dateTime.year().month().day().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(appTheme.secondaryText)
                        }
                        Spacer()
                        Text(Self.sizeText(file.size))
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }
                }

                Button(role: .destructive, action: onCleanUp) {
                    Label(
                        "保留 1 份，移入废纸篓 \(group.filesToDelete.count) 个",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(group.filesToDelete.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}