import SwiftUI

struct MaterialsListView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    /// 分类筛选。侧栏的「课件 / 真题 / 笔记」对应 `MaterialCategory`，
    /// 不是文件类型 `MaterialType`——两者是不同的维度。
    let filter: MaterialCategory?
    var favoritesOnly: Bool = false

    @State private var showCreateSheet = false
    @State private var selectedMaterial: StudyMaterial?
    @State private var isEditing = false
    @State private var selectedMaterials: Set<UUID> = []

    var body: some View {
        Group {
            if filteredMaterials.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .searchable(text: $appState.searchText, prompt: "搜索资料...")
        .refreshable {
            // 下拉刷新
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isEditing {
                    Button("全选") {
                        selectedMaterials = Set(filteredMaterials.map { $0.id })
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if isEditing {
                        Button("取消") { isEditing = false; selectedMaterials.removeAll() }
                        Button("删除") {
                            appState.deleteMaterials(withIDs: Array(selectedMaterials))
                            isEditing = false
                            selectedMaterials.removeAll()
                        }
                        .foregroundStyle(.red)
                    } else {
                        Menu {
                            Button("新建文本资料") { showCreateSheet = true }
                            Button("扫描文档") { appState.startDocumentScan() }
                            Button("语音笔记") { appState.startVoiceMemo() }
                            Divider()
                            Button("从文件导入") { appState.showFileImporter = true }
                        } label: {
                            Image(systemName: "plus")
                        }
                        Button { isEditing = true } label: { Image(systemName: "checkmark.circle") }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateMaterialView_iOS()
                .environmentObject(appState)
        }
        .sheet(item: $selectedMaterial) { material in
            MaterialDetailView_iOS(material: material)
                .environmentObject(appState)
        }
    }

    private var filteredMaterials: [StudyMaterial] {
        var result = appState.materials
        if let filter = filter { result = result.filter { $0.category == filter } }
        if favoritesOnly { result = result.filter { $0.isFavorite } }
        if !appState.searchText.isEmpty {
            result = result.filter { material in
                material.name.localizedCaseInsensitiveContains(appState.searchText) ||
                (material.keywords?.contains { $0.localizedCaseInsensitiveContains(appState.searchText) } ?? false) ||
                material.content.localizedCaseInsensitiveContains(appState.searchText)
            }
        }
        // 按最后修改时间倒序：`StudyMaterial` 的字段名是 `modifiedAt`。
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无资料", systemImage: "folder")
        } description: {
            Text("点击右上角 + 导入或创建第一份资料")
        } actions: {
            Button("导入资料") { appState.showFileImporter = true }
                .buttonStyle(.borderedProminent)
            Button("扫描文档") { appState.startDocumentScan() }
                .buttonStyle(.bordered)
            Button("语音笔记") { appState.startVoiceMemo() }
                .buttonStyle(.bordered)
        }
    }

    private var listContent: some View {
        List(selection: $selectedMaterials) {
            ForEach(filteredMaterials) { material in
                MaterialRow_iOS(material: material, isEditing: isEditing, isSelected: selectedMaterials.contains(material.id))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isEditing {
                            if selectedMaterials.contains(material.id) {
                                selectedMaterials.remove(material.id)
                            } else {
                                selectedMaterials.insert(material.id)
                            }
                        } else {
                            selectedMaterial = material
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            appState.deleteMaterial(material)
                        } label: { Label("删除", systemImage: "trash") }

                        Button {
                            // 编辑
                        } label: { Label("编辑", systemImage: "pencil") }
                        .tint(.blue)

                        Button {
                            // 收藏
                        } label: {
                            Label(material.isFavorite ? "取消收藏" : "收藏", systemImage: material.isFavorite ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            // 分享
                        } label: { Label("分享", systemImage: "square.and.arrow.up") }
                        .tint(.green)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
    }
}

struct MaterialRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let material: StudyMaterial
    let isEditing: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? appTheme.accent : appTheme.secondaryText)
                    .font(.title2)
            }

            // 类型图标
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(typeColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: typeIcon)
                    .font(.title2)
                    .foregroundStyle(typeColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(material.name)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(material.type.displayName, systemImage: typeIcon)
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)

                    if let keywords = material.keywords, !keywords.isEmpty {
                        Text("· \(keywords.prefix(2).joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Text(material.modifiedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }
            }

            Spacer()

            if material.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.vertical, 4)
    }

    // 图标与配色复用 Shared/Models/StudyMaterial.swift 的映射，
    // 避免同一个 `MaterialType` 在多个视图里各写一份 switch。
    private var typeIcon: String { material.type.icon }

    private var typeColor: Color { material.type.color }
}

struct CreateMaterialView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var name = ""
    @State private var content = ""
    @State private var type: MaterialType = .text

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("资料名称", text: $name)
                    Picker("类型", selection: $type) {
                        ForEach(MaterialType.allCases, id: \.rawValue) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                }

                Section("内容") {
                    if type == .text || type == .markdown {
                        TextEditor(text: $content)
                            .frame(minHeight: 200)
                    } else {
                        Text("请通过导入或扫描添加 \(type.displayName) 文件")
                            .foregroundStyle(appTheme.secondaryText)
                    }
                }
            }
            .navigationTitle("新建资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let material = StudyMaterial(name: name, type: type, content: content)
                        appState.materials.insert(material, at: 0)
                        appState.storageService.saveMaterials(appState.materials)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

struct MaterialDetailView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    let material: StudyMaterial

    @State private var showOCR = false
    @State private var showKeywords = false
    @State private var showAIAnalysis = false
    @State private var editContent = ""
    @State private var isEditing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 文件预览/内容
                    if let localURL = material.localURL, material.type == .pdf {
                        PDFPreviewView(url: localURL)
                            .frame(height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if let localURL = material.localURL, material.type == .image {
                        AsyncImage(url: localURL) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // 文本内容
                    if isEditing {
                        TextEditor(text: $editContent)
                            .frame(minHeight: 200)
                            .padding(12)
                            .background(appTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if !material.content.isEmpty {
                        Text(material.content)
                            .font(.body)
                            .foregroundStyle(appTheme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 提取的文字
                    if let extractedText = material.extractedText, !extractedText.isEmpty {
                        DisclosureGroup("识别文字") {
                            Text(extractedText)
                                .font(.caption)
                                .foregroundStyle(appTheme.secondaryText)
                                .textSelection(.enabled)
                        }
                    }

                    // 关键词
                    if let keywords = material.keywords, !keywords.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(keywords, id: \.self) { keyword in
                                    Text(keyword)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(appTheme.accent.opacity(0.15))
                                        .foregroundStyle(appTheme.accent)
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(material.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isEditing.toggle()
                        if isEditing { editContent = material.content }
                    } label: { Image(systemName: isEditing ? "checkmark" : "pencil") }

                    Menu {
                        Button { showOCR = true } label: { Label("OCR 识别", systemImage: "text.viewfinder") }
                        Button { showKeywords = true } label: { Label("提取关键词", systemImage: "key.fill") }
                        Button { showAIAnalysis = true } label: { Label("AI 分析", systemImage: "brain.head.profile") }
                        Divider()
                        Button(role: .destructive) {
                            appState.deleteMaterial(material)
                            dismiss()
                        } label: { Label("删除", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showOCR) {
                OCRProgressView(material: material)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showKeywords) {
                KeywordsProgressView(material: material)
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showAIAnalysis) {
                AIAnalysisView(material: material)
                    .environmentObject(appState)
            }
        }
    }
}

struct OCRProgressView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    let material: StudyMaterial

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("正在识别文字...")
                    .font(.headline)
                Text("请稍候，这可能需要几秒钟")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("OCR 识别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                appState.processOCR(for: material)
            }
            .onChange(of: appState.isProcessingOCR) { _, isProcessing in
                if !isProcessing { dismiss() }
            }
        }
    }
}

struct KeywordsProgressView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    let material: StudyMaterial

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("正在提取关键词...")
                    .font(.headline)
            }
            .padding()
            .navigationTitle("提取关键词")
            .onAppear { appState.extractKeywords(for: material) }
            .onChange(of: appState.isExtractingKeywords) { _, isProcessing in
                if !isProcessing { dismiss() }
            }
        }
    }
}

struct AIAnalysisView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    let material: StudyMaterial

    @State private var question = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if appState.isAnalyzingWithAI {
                    ProgressView("AI 正在思考...")
                        .scaleEffect(1.2)
                } else if !appState.aiAnalysisResult.isEmpty {
                    ScrollView {
                        Text(appState.aiAnalysisResult)
                            .padding()
                    }
                } else {
                    VStack(spacing: 12) {
                        TextField("输入你想问的问题...", text: $question, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)

                        Button("提问") {
                            appState.analyzeWithAI(for: material)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(question.isEmpty)
                    }
                    .padding()
                }
            }
            .navigationTitle("AI 分析")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}

struct PDFPreviewView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        if let document = PDFDocument(url: url) {
            pdfView.document = document
        }
        return pdfView
    }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

import PDFKit