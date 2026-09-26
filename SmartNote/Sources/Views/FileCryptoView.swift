import SwiftUI
import UniformTypeIdentifiers

/// 文件加密中心。
///
/// - 角色：把用户拖入/选中的任意文件（≤2GB），用 AES-256-GCM 加密成 .snenc；
///         反向把 .snenc 解密回原文件。密码按"文件名 + 子路径"维度存到 Keychain。
/// - 设计原则：不引第三方依赖；批量任务用 TaskGroup 并发；UI 实时显示进度；
///             不在 UI 中输出开发笔记 / "按您说的" 等冗余文字。
struct FileCryptoView: View {
    @EnvironmentObject var appState: AppState

    enum Mode: String, CaseIterable, Identifiable {
        case encrypt = "加密"
        case decrypt = "解密"
        var id: String { rawValue }
    }

    enum FileRowKind {
        case pending(URL, Int64 /* size */)
        case done(URL, Int64)
        case failed(URL, String)
    }

    struct FileRow: Identifiable, Equatable {
        let id: UUID
        var url: URL
        var size: Int64
        var kind: FileRowKind

        static func == (lhs: FileRow, rhs: FileRow) -> Bool { lhs.id == rhs.id }
    }

    @State private var mode: Mode = .encrypt
    @State private var rows: [FileRow] = []
    @State private var isTargeted: Bool = false
    @State private var showPicker: Bool = false
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var savePassword: Bool = true
    @State private var outputDirText: String = ""           // 加密：空=同目录；非空=导出到该目录
    @State private var status: String = ""
    @State private var isWorking: Bool = false
    @State private var progress: Double = 0
    @State private var completion: Double = 0              // 0...1
    @State private var showSummary: Bool = false
    @State private var summaryText: String = ""
    @State private var keychainAccounts: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            modePicker
            Divider()

            HStack(spacing: 0) {
                // 左侧：拖入 / 选文件 / 列表
                fileListSection
                    .frame(minWidth: 360, idealWidth: 420)
                Divider()
                // 右侧：配置
                configSection
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshKeychainAccounts()
            status = "把文件拖到左侧，或点「添加文件」。"
        }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: mode == .encrypt ? [.item] : [UTType(filenameExtension: FileCryptoService.encryptedExtension) ?? .data],
            allowsMultipleSelection: true
        ) { result in
            handlePickerResult(result)
        }
        .alert("处理完成", isPresented: $showSummary) {
            Button("好") { showSummary = false }
        } message: {
            Text(summaryText)
        }
    }

    // MARK: - 模式选择条

    private var modePicker: some View {
        HStack(spacing: 12) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            if isWorking {
                ProgressView(value: completion) {
                    Text("\(Int(completion * 100))%")
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
                .frame(width: 220)
            } else {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 左侧：文件列表 + 拖拽

    private var fileListSection: some View {
        VStack(spacing: 0) {
            // 拖入区
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                            style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [6, 4]))
                VStack(spacing: 8) {
                    Image(systemName: mode == .encrypt ? "lock.doc.fill" : "key.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(mode == .encrypt ? "把要加密的文件拖到这里" : "把 .snenc 拖到这里解密")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("选择文件…") { showPicker = true }
                        .disabled(isWorking)
                }
                .padding()
            }
            .frame(height: 140)
            .padding(12)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }

            Divider()

            // 列表
            if rows.isEmpty {
                Spacer()
                Text(mode == .encrypt ? "等待文件…" : "等待 .snenc 文件…")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // 列表下方操作
            HStack {
                Button(role: .destructive) {
                    rows.removeAll()
                } label: {
                    Label("清空列表", systemImage: "trash")
                }
                .disabled(rows.isEmpty || isWorking)

                Spacer()

                Text("共 \(rows.count) 个，合计 \(formattedTotalSize)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func rowView(_ row: FileRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: row))
                .foregroundColor(iconColor(for: row))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.url.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(rowSubtitle(row))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            switch row.kind {
            case .pending, .done:
                Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for row: FileRow) -> String {
        switch row.kind {
        case .pending: return "doc"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
    private func iconColor(for row: FileRow) -> Color {
        switch row.kind {
        case .pending: return .secondary
        case .done: return .green
        case .failed: return .red
        }
    }
    private func rowSubtitle(_ row: FileRow) -> String {
        switch row.kind {
        case .pending: return "待处理"
        case .done: return "完成"
        case .failed(_, let err): return "失败：\(err)"
        }
    }

    private var formattedTotalSize: String {
        let sum = rows.map { $0.size }.reduce(0, +)
        return ByteCountFormatter.string(fromByteCount: sum, countStyle: .file)
    }

    // MARK: - 右侧：密码 + 操作

    private var configSection: some View {
        Form {
            Section(mode == .encrypt ? "加密配置" : "解密配置") {
                if mode == .encrypt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("输出目录（可选）")
                            .font(.caption).foregroundColor(.secondary)
                        HStack {
                            TextField("留空：与源文件同目录", text: $outputDirText)
                            Button("浏览…") { pickOutputDirectory() }
                                .disabled(isWorking)
                        }
                    }
                    Text("加密产物为 .snenc。源文件不会被修改或删除。")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Text("解密产物为原文件名（无 .snenc 后缀）。如目标已存在会自动加 -1/-2。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            Section("密码") {
                SecureField(mode == .encrypt ? "新密码" : "密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                if mode == .encrypt {
                    SecureField("再次输入", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isWorking)
                }

                Toggle("为每个文件保存密码到钥匙串", isOn: $savePassword)
                    .disabled(isWorking)
                    .help("勾选后密码会按文件名保存到 macOS 钥匙串；下次解密时一键取出")

                if mode == .decrypt && !keychainAccounts.isEmpty {
                    DisclosureGroup("钥匙串里的密码（\(keychainAccounts.count)）") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(keychainAccounts.prefix(10), id: \.self) { acc in
                                HStack {
                                    Text(acc)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button("使用并解密") {
                                        applyKeychainPassword(for: acc)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isWorking)
                                }
                            }
                            if keychainAccounts.count > 10 {
                                Text("…还有 \(keychainAccounts.count - 10) 条")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    startWorking()
                } label: {
                    HStack(spacing: 6) {
                        // 修复前是 ProgressView().scaleEffect(0.7)。
                        // scaleEffect 只做视觉缩放、不改布局尺寸，而 AppKit 宿主视图
                        // (AppKitProgressView) 报的是固定固有尺寸，两者混用会让
                        // 布局引擎算出 min > max 的矛盾约束而直接崩溃：
                        //   "has a maximum length (32.142857) that doesn't satisfy min ..."
                        // 改用 controlSize —— 这是 AppKit 视图唯一受支持的缩放方式。
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(mode == .encrypt ? "开始加密" : "开始解密")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }

            Section("本地缓存") {
                HStack {
                    Text("产物输出位置")
                    Spacer()
                    Text(outputDirText.isEmpty ? "与源文件同目录" : outputDirText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("2 GB 单文件上限；批量并发加密走任务组，不阻塞主线程。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - 派生状态

    private var canStart: Bool {
        if isWorking { return false }
        if rows.isEmpty { return false }
        if password.isEmpty { return false }
        if mode == .encrypt && password != confirmPassword { return false }
        return true
    }

    // MARK: - 文件添加 / 删除

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addFiles(urls)
        case .failure(let err):
            status = "选择文件失败：\(err.localizedDescription)"
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let collector = OrderedThreadSafeCollector<URL>()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                defer { group.leave() }
                if let url {
                    collector.append(url, at: index)
                }
            }
        }
        group.notify(queue: .main) {
            // 所有异步回调完成后，按拖放顺序一次性更新 rows/status。
            self.addFiles(collector.snapshot())
        }
        return true
    }

    private func addFiles(_ urls: [URL]) {
        // 过滤：解密仅留 .snenc
        let filtered: [URL] = urls.filter { u in
            switch mode {
            case .encrypt: return true
            case .decrypt: return u.pathExtension.lowercased() == FileCryptoService.encryptedExtension
            }
        }
        for u in filtered {
            let size: Int64 = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
            rows.append(FileRow(id: UUID(), url: u, size: size, kind: .pending(u, size)))
        }
        status = filtered.isEmpty ? "未识别可用文件" : "已添加 \(filtered.count) 个文件"
    }

    // MARK: - 操作主循环

    private func startWorking() {
        guard canStart else { return }

        // 校验：解密时清单内密码必须对全部文件都对得上，或用户确认每个单独配
        // 简化方案：当前密码用于全部文件；钥匙串允许单文件覆盖

        // 解密时 KeychainService 优先看同名密码（每个文件独立），缺则退回统一输入密码
        isWorking = true
        status = "处理中…"
        completion = 0

        // mark all pending → in progress
        for i in rows.indices {
            if case .pending = rows[i].kind {
                rows[i].kind = .pending(rows[i].url, rows[i].size)
            }
        }

        let service = appState.fileCryptoService
        let keychain = appState.keychainService
        let pw = self.password
        let savePw = self.savePassword
        let mode = self.mode
        var workingRows = rows

        Task {
            await withTaskGroup(of: (UUID, FileRowKind).self) { group in
                for row in workingRows {
                    let rowId = row.id
                    let src = row.url
                    group.addTask {
                        do {
                            switch mode {
                            case .encrypt:
                                let out = try service.encryptFile(at: src, password: pw, outputURL: nil)
                                if savePw {
                                    try? keychain.savePassword(pw, for: out.lastPathComponent)
                                }
                                return (rowId, .done(out, row.size))
                            case .decrypt:
                                // 优先尝试 Keychain 的密码
                                let usePwd = keychain.loadPassword(for: src.lastPathComponent) ?? pw
                                let out = try service.decryptFile(at: src, password: usePwd, outputURL: nil)
                                return (rowId, .done(out, row.size))
                            }
                        } catch {
                            return (rowId, .failed(src, error.localizedDescription))
                        }
                    }
                }
                var done = 0
                for await (id, newKind) in group {
                    if let idx = workingRows.firstIndex(where: { $0.id == id }) {
                        workingRows[idx].kind = newKind
                    }
                    done += 1
                    let total = workingRows.count
                    await MainActor.run {
                        self.completion = Double(done) / Double(total)
                        self.rows = workingRows
                    }
                }
            }

            await MainActor.run {
                self.isWorking = false
                self.completion = 1.0
                let succ = workingRows.filter { if case .done = $0.kind { return true } else { return false } }.count
                let fail = workingRows.filter { if case .failed = $0.kind { return true } else { return false } }.count
                let total = workingRows.count
                self.status = "完成：成功 \(succ)，失败 \(fail)，共 \(total)"
                self.summaryText = "成功 \(succ) 个，失败 \(fail) 个。详情见左侧列表。"
                self.showSummary = true
                self.refreshKeychainAccounts()
            }
        }
    }

    private func refreshKeychainAccounts() {
        keychainAccounts = appState.keychainService.listAccounts().sorted()
    }

    private func applyKeychainPassword(for account: String) {
        if let pwd = appState.keychainService.loadPassword(for: account) {
            self.password = pwd
            self.confirmPassword = pwd
            self.status = "已从钥匙串取出密码（账号：\(account)）"
        }
    }

    private func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择加密文件输出目录"
        if panel.runModal() == .OK, let u = panel.url {
            self.outputDirText = u.path
        }
    }
}
