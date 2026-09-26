import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiaryEditorView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    /// 由 SmartNoteApp 的「日记编辑器」窗口注入，用于把 linkedMaterialIDs 解析成资料名。
    @EnvironmentObject private var appState: AppState
    @StateObject private var diaryService = DiaryService.shared
    @StateObject private var whiteboardService = WhiteboardService.shared
    
    let entryID: UUID?
    let isNew: Bool
    
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var category: String = "默认"
    @State private var linkedMaterials: [UUID] = []
    @State private var imagePaths: [String] = []
    @State private var whiteboardID: UUID? = nil
    @State private var showPreview = false
    @State private var showMaterialPicker = false
    @State private var showCategoryPicker = false
    @State private var showWhiteboardPicker = false
    @State private var showImagePicker = false
    @State private var entryLoaded = false
    @State private var decryptionFailed = false
    @State private var showOperationError = false
    @State private var operationErrorMessage = ""
    
    // 添加分类
    @State private var showAddCategorySheet = false
    @State private var newCategoryName: String = ""
    
    init(entryID: UUID? = nil) {
        self.entryID = entryID
        self.isNew = entryID == nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            editorContent
        }
        .frame(minWidth: 700, minHeight: 600)
        .task(id: entryID) {
            loadEntryData()
        }
        .alert("日记操作失败", isPresented: $showOperationError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(operationErrorMessage)
        }
    }
    
    private var isNewEntry: Bool { entryID == nil }
    
    private func loadEntryData() {
        // 只在第一次加载，避免 view 重建时覆盖用户正在编辑的内容
        guard !entryLoaded else { return }
        if let id = entryID, let entry = diaryService.entries.first(where: { $0.id == id }) {
            title = entry.title
            category = entry.category
            linkedMaterials = entry.linkedMaterialIDs
            imagePaths = entry.imagePaths
            whiteboardID = entry.whiteboardID

            if entry.isEncrypted {
                switch diaryService.decryptEntry(entry) {
                case .success(let decrypted):
                    content = decrypted.content
                case .failure(let error):
                    // 不用空内容或密文冒充解密成功；同时阻止用户无意保存空正文
                    // 覆盖一个尚未成功读取的加密日记。
                    content = ""
                    decryptionFailed = true
                    presentOperationError(error.localizedDescription)
                }
            } else {
                content = entry.content
            }
        }
        // 新建日记：保持默认状态（空标题/空内容/默认分类），不要覆盖用户输入
        entryLoaded = true
    }
    
    // MARK: - 头部
    
    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button("取消") {
                dismissWindow()
            }
            .buttonStyle(.bordered)
            
            Spacer()
            
            Text(isNewEntry ? "新建日记" : "编辑日记")
                .font(.headline)
            
            Spacer()
            
            Button {
                showPreview.toggle()
            } label: {
                Image(systemName: showPreview ? "eye.slash" : "eye")
            }
            .buttonStyle(.bordered)
            
            Button {
                if saveEntry() {
                    dismissWindow()
                }
            } label: {
                Text("保存")
            }
            .buttonStyle(.borderedProminent)
            .disabled(decryptionFailed)
        }
        .padding()
    }
    
    // MARK: - 内容区
    
    private var editorContent: some View {
        VStack(spacing: 0) {
            // 标题和元数据
            VStack(spacing: 8) {
                TextField("日记标题", text: $title)
                    .font(.title2)
                    .textFieldStyle(.plain)
                
                HStack(spacing: 8) {
                    Button {
                        showCategoryPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                            Text(category)
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .popover(isPresented: $showCategoryPicker) {
                        categoryPopover
                    }
                    
                    Button {
                        showMaterialPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            // 显示已关联数量，否则选了多份资料时看不出选了几份
                            Text(linkedMaterials.isEmpty
                                 ? "关联资料"
                                 : "关联资料(\(linkedMaterials.count))")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        showImagePicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                            Text(imagePaths.isEmpty ? "插入图片" : "图片(\(imagePaths.count))")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Button {
                        showWhiteboardPicker = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "scribble.variable")
                            Text(whiteboardID == nil ? "插入白板" : "白板✓")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    Text("\(DiaryEntry.countWords(in: content)) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
            // 已关联资料清单。
            // 修复前 linkedMaterials 只被写入、从未展示：关联多份时看不出关联了哪些。
            if !linkedMaterials.isEmpty {
                linkedMaterialsStrip
            }

            // 已选图片预览
            if !imagePaths.isEmpty {
                imagePreviewStrip
            }
            
            // 白板预览
            if let wbID = whiteboardID, let wb = whiteboardService.documents.first(where: { $0.id == wbID }) {
                whiteboardPreview(wb)
            }
            
            Divider()
            
            // 编辑/预览
            if showPreview && !decryptionFailed {
                previewView
            } else {
                editorView
            }
        }
        .sheet(isPresented: $showMaterialPicker) {
            MaterialPickerView(selectedIDs: $linkedMaterials)
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(selectedPaths: $imagePaths)
        }
        .sheet(isPresented: $showWhiteboardPicker) {
            WhiteboardPickerView(selectedID: $whiteboardID)
        }
        .sheet(isPresented: $showAddCategorySheet) {
            addCategorySheet
        }
    }
    
    // MARK: - 图片预览条
    
    /// 已关联资料清单。逐条显示资料名，并允许单独解除关联。
    /// 资料已被删除时保留占位并说明，避免条目静默消失。
    private var linkedMaterialsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "link")
                Text("已关联 \(linkedMaterials.count) 份资料")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            ForEach(linkedMaterials, id: \.self) { id in
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(materialName(for: id))
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        linkedMaterials.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("解除关联")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func materialName(for id: UUID) -> String {
        appState.materials.first(where: { $0.id == id })?.name ?? "（资料已删除）"
    }

    private var imagePreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(imagePaths, id: \.self) { path in
                    if let nsImage = NSImage(contentsOfFile: path) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                            .contextMenu {
                                Button(role: .destructive) {
                                    imagePaths.removeAll { $0 == path }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    
    // MARK: - 白板预览
    
    private func whiteboardPreview(_ wb: WhiteboardDocument) -> some View {
        HStack {
            Image(systemName: "scribble.variable")
                .foregroundColor(.purple)
            VStack(alignment: .leading) {
                Text("已关联白板")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(wb.name)
                    .font(.subheadline)
            }
            Spacer()
            Button("移除") {
                whiteboardID = nil
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.purple.opacity(0.05))
    }
    
    // MARK: - 编辑器
    
    private var editorView: some View {
        Group {
            if decryptionFailed {
                VStack(spacing: 10) {
                    Image(systemName: "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("日记尚未成功解密，编辑和保存已禁用")
                        .font(.headline)
                    Text("请确认钥匙串中的密码或数据完整性后重新打开此日记。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextEditor(text: $content)
                    .font(.body)
                    .padding(8)
            }
        }
    }
    
    // MARK: - 预览
    
    private var previewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !title.isEmpty {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                }
                MarkdownText(content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // 显示图片
                if !imagePaths.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
                        ForEach(imagePaths, id: \.self) { path in
                            if let nsImage = NSImage(contentsOfFile: path) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxHeight: 200)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    
    // MARK: - 分类选择弹窗
    
    private var categoryPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择分类")
                .font(.headline)
                .padding()
            
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(diaryService.categories) { cat in
                        Button {
                            category = cat.name
                            showCategoryPicker = false
                        } label: {
                            HStack {
                                Circle()
                                    .fill(Color(hex: cat.color) ?? .blue)
                                    .frame(width: 10, height: 10)
                                Text(cat.name)
                                Spacer()
                                if category == cat.name {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
            
            Divider()
            
            Button {
                newCategoryName = ""
                showAddCategorySheet = true
            } label: {
                Label("新建分类", systemImage: "plus")
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200)
    }
    
    // MARK: - 新建分类 Sheet
    
    private var addCategorySheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") {
                    showAddCategorySheet = false
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Text("新建分类")
                    .font(.headline)
                
                Spacer()
                
                Button("保存") {
                    let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // 随机颜色调色板
                        let palette = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF3B30", "#5856D6", "#FF2D55", "#5AC8FA"]
                        let color = palette[diaryService.categories.count % palette.count]
                        let newCat = DiaryCategory(name: trimmed, color: color)
                        diaryService.addCategory(newCat)
                        // 自动选中新分类
                        category = trimmed
                    }
                    showAddCategorySheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("分类名称")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                TextField("例如：学习、生活、工作", text: $newCategoryName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let palette = ["#007AFF", "#34C759", "#FF9500", "#AF52DE", "#FF3B30", "#5856D6", "#FF2D55", "#5AC8FA"]
                            let color = palette[diaryService.categories.count % palette.count]
                            let newCat = DiaryCategory(name: trimmed, color: color)
                            diaryService.addCategory(newCat)
                            category = trimmed
                            showAddCategorySheet = false
                        }
                    }
            }
            .padding()
            
            Spacer()
        }
        .frame(width: 360, height: 200)
    }
    
    // MARK: - 保存
    
    private func saveEntry() -> Bool {
        guard !decryptionFailed else {
            presentOperationError("解密失败：密码错误 或 数据已损坏；本次未保存")
            return false
        }

        let result: Result<Void, DiaryEncryptionError>
        if isNewEntry {
            let newEntry = DiaryEntry(
                id: UUID(),
                title: title,
                content: content,
                category: category,
                createdAt: Date(),
                updatedAt: Date(),
                isPinned: false,
                linkedMaterialIDs: linkedMaterials,
                isEncrypted: false,
                imagePaths: imagePaths,
                whiteboardID: whiteboardID
            )
            result = diaryService.addEntry(newEntry)
        } else if let id = entryID, var existing = diaryService.entries.first(where: { $0.id == id }) {
            existing.title = title
            existing.content = content
            existing.category = category
            existing.updatedAt = Date()
            existing.linkedMaterialIDs = linkedMaterials
            existing.imagePaths = imagePaths
            existing.whiteboardID = whiteboardID
            // 正文已经是编辑器中的明文，不能保留旧的 isEncrypted 标志，否则
            // DiaryService 会把明文误当成另一层密文。
            existing.isEncrypted = false
            result = diaryService.updateEntry(existing)
        } else {
            presentOperationError("找不到要保存的日记，本次未保存")
            return false
        }

        switch result {
        case .success:
            return true
        case .failure(let error):
            // 这里明确选择“未保存”，而不是把明文作为未加密草稿落盘。
            presentOperationError(
                "加密失败，本次未保存（请注意；不会保存为未加密草稿，未写入日记库）\n\(error.localizedDescription)"
            )
            return false
        }
    }

    private func presentOperationError(_ message: String) {
        operationErrorMessage = message
        showOperationError = true
    }
}

// MARK: - 图片选择器

struct ImagePickerView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var selectedPaths: [String]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择图片")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()
            
            Divider()
            
            VStack(spacing: 12) {
                if selectedPaths.isEmpty {
                    Text("尚未选择图片")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(selectedPaths, id: \.self) { path in
                                HStack {
                                    Image(systemName: "photo")
                                        .foregroundColor(.blue)
                                    Text((path as NSString).lastPathComponent)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        selectedPaths.removeAll { $0 == path }
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                
                Divider()
                
                Button {
                    selectImages()
                } label: {
                    Label("从相册选择", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
        .frame(width: 400, height: 350)
    }
    
    private func selectImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType.image, UTType.png, UTType.jpeg, UTType.gif, UTType.webP]
        panel.message = "选择要插入的图片"
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                // 复制到日记图片目录
                let savedPath = copyImageToDiaryFolder(url)
                if !selectedPaths.contains(savedPath) {
                    selectedPaths.append(savedPath)
                }
            }
        }
    }
    
    private func copyImageToDiaryFolder(_ url: URL) -> String {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths.first!.appendingPathComponent("SmartNote/DiaryImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: appSupport.path) {
            try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        
        let filename = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let dest = appSupport.appendingPathComponent(filename)
        
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest.path
        } catch {
            print("[ImagePicker] Copy failed: \(error)")
            return url.path
        }
    }
}

// MARK: - 白板选择器

struct WhiteboardPickerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var whiteboardService = WhiteboardService.shared
    @Binding var selectedID: UUID?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择白板")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()
            
            Divider()
            
            List(whiteboardService.documents) { doc in
                HStack {
                    Image(systemName: "scribble.variable")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading) {
                        Text(doc.name)
                            .font(.subheadline)
                        Text("\(doc.objects.count) 个对象")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if selectedID == doc.id {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedID = doc.id
                    dismiss()
                }
            }
            .frame(width: 400, height: 400)
        }
    }
}

// MARK: - 资料选择器

struct MaterialPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @Binding var selectedIDs: [UUID]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("关联资料")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()
            
            Divider()
            
            List(appState.materials) { material in
                HStack {
                    Image(systemName: selectedIDs.contains(material.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(selectedIDs.contains(material.id) ? .accentColor : .secondary)
                    
                    Text(material.name)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(material.id)
                }
            }
        }
        .frame(width: 300, height: 400)
    }
    
    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.removeAll { $0 == id }
        } else {
            selectedIDs.append(id)
        }
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}
