import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiaryEditorView: View {
    @Environment(\.dismiss) private var dismiss
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
    
    init(entry: DiaryEntry? = nil) {
        self.entryID = entry?.id
        self.isNew = entry == nil
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
    }
    
    private var isNewEntry: Bool { entryID == nil }
    
    private func loadEntryData() {
        if let id = entryID, let entry = diaryService.entries.first(where: { $0.id == id }) {
            title = entry.title
            content = entry.content
            category = entry.category
            linkedMaterials = entry.linkedMaterialIDs
            imagePaths = entry.imagePaths
            whiteboardID = entry.whiteboardID
            
            if entry.isEncrypted, let decrypted = diaryService.decryptEntry(entry) {
                content = decrypted.content
            }
            entryLoaded = true
        } else {
            if !entryLoaded {
                entryLoaded = true
            }
        }
    }
    
    // MARK: - 头部
    
    private var editorHeader: some View {
        HStack(spacing: 12) {
            Button("取消") {
                dismiss()
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
                saveEntry()
                dismiss()
            } label: {
                Text("保存")
            }
            .buttonStyle(.borderedProminent)
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
                            Text("关联资料")
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
                    
                    Text("\(chineseWordCount) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            
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
            if showPreview {
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
    }
    
    // MARK: - 图片预览条
    
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
        TextEditor(text: $content)
            .font(.body)
            .padding(8)
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
                let newCat = DiaryCategory(name: "新分类 \(diaryService.categories.count + 1)")
                diaryService.addCategory(newCat)
            } label: {
                Label("新建分类", systemImage: "plus")
                    .padding()
            }
            .buttonStyle(.plain)
        }
        .frame(width: 200)
    }
    
    // MARK: - 计算属性
    
    private var chineseWordCount: Int {
        let chineseChars = content.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        }.count
        let englishWords = content.split { !$0.isLetter && !$0.isNumber }.count
        return chineseChars + englishWords
    }
    
    // MARK: - 保存
    
    private func saveEntry() {
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
            diaryService.addEntry(newEntry)
        } else if let id = entryID, var existing = diaryService.entries.first(where: { $0.id == id }) {
            existing.title = title
            existing.content = content
            existing.category = category
            existing.updatedAt = Date()
            existing.linkedMaterialIDs = linkedMaterials
            existing.imagePaths = imagePaths
            existing.whiteboardID = whiteboardID
            diaryService.updateEntry(existing)
        }
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
