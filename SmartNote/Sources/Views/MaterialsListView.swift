import SwiftUI
import AppKit
import PDFKit

struct MaterialsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editingMaterial: StudyMaterial?
    @State private var showCreateMaterial = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var lastSelectedIndex: Int? = nil
    @State private var showBatchKeywordSheet: Bool = false
    @State private var batchKeywordInput: String = ""
    
    var filter: MaterialCategory?
    var favoritesOnly: Bool = false
    
    private var displayedMaterials: [StudyMaterial] {
        var materials = appState.filteredMaterials
        
        if let filter = filter {
            materials = materials.filter { $0.category == filter }
        }
        
        if favoritesOnly {
            materials = materials.filter { $0.isFavorite }
        }
        
        return materials.sorted { $0.modifiedAt > $1.modifiedAt }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            toolbarView
            
            if displayedMaterials.isEmpty {
                emptyStateView
            } else {
                materialsList
            }
        }
        .sheet(item: $editingMaterial) { material in
            MaterialDetailView(material: material)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showCreateMaterial) {
            CreateMaterialView()
                .environmentObject(appState)
        }
    }
    
    private var toolbarView: some View {
        HStack {
            TextField("搜索资料...", text: $appState.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            
            Spacer()
            // selection toolbar
            if !selectedIDs.isEmpty {
                Text("已选中 \(selectedIDs.count) 项")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if selectedIDs.count == 1 {
                    Button {
                        if let id = selectedIDs.first, let m = appState.materials.first(where: { $0.id == id }) {
                            editingMaterial = m
                            // keep selection
                        }
                    } label: {
                        Label("打开所选", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    // batch add keywords
                    batchKeywordInput = ""
                    showBatchKeywordSheet = true
                } label: {
                    Label("添加关键词", systemImage: "tag")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    let ids = Array(selectedIDs)
                    appState.deleteMaterials(withIDs: ids)
                    selectedIDs.removeAll()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button {
                    exportSelected()
                } label: {
                    Label("导出所选", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            
            if appState.isScanning {
                ProgressView()
                    .scaleEffect(0.8)
                Text("正在扫描...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Menu {
                Button {
                    showCreateMaterial = true
                } label: {
                    Label("新建资料", systemImage: "doc.badge.plus")
                }
                
                Button {
                    appState.showFileImporter = true
                } label: {
                    Label("导入文件", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("添加", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 80)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("暂无资料")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("点击下方按钮添加学习资料")
                .font(.body)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button {
                    showCreateMaterial = true
                } label: {
                    Label("新建资料", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    appState.showFileImporter = true
                } label: {
                    Label("导入文件", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var materialsList: some View {
        List {
            ForEach(Array(displayedMaterials.enumerated()), id: \.element.id) { idx, material in
                MaterialRowView(
                    material: material,
                    searchText: appState.searchText,
                    isSelected: selectedIDs.contains(material.id),
                    onSelect: {
                        let flags = NSEvent.modifierFlags
                        if flags.contains(.command) {
                            if selectedIDs.contains(material.id) {
                                selectedIDs.remove(material.id)
                            } else {
                                selectedIDs.insert(material.id)
                            }
                            lastSelectedIndex = idx
                        } else if flags.contains(.shift), let last = lastSelectedIndex {
                            // select range
                            let range = min(last, idx)...max(last, idx)
                            let ids = displayedMaterials.enumerated().compactMap { (i, m) -> UUID? in
                                range.contains(i) ? m.id : nil
                            }
                            selectedIDs.formUnion(ids)
                        } else {
                            // open detail
                            selectedIDs.removeAll()
                            editingMaterial = material
                            lastSelectedIndex = idx
                        }
                    }
                )
                .contextMenu {
                    Button {
                        toggleFavorite(material)
                    } label: {
                        Label(
                            material.isFavorite ? "取消收藏" : "收藏",
                            systemImage: material.isFavorite ? "star.slash" : "star"
                        )
                    }
                    
                    Divider()
                    
                    Button {
                        appState.processOCR(for: material)
                    } label: {
                        Label("文字识别 (OCR)", systemImage: "text.viewfinder")
                    }
                    .disabled(material.type != .image)
                    
                    Button {
                        appState.extractKeywords(for: material)
                    } label: {
                        Label("提取考点", systemImage: "brain.head.profile")
                    }
                    .disabled(material.extractedText?.isEmpty ?? true && material.content.isEmpty)
                    
                    Divider()
                    
                    Button(role: .destructive) {
                        appState.deleteMaterial(material)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .onTapGesture {
                    // handled via row onSelect; keep tap for selection without modifiers
                }
        }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .sheet(isPresented: $showBatchKeywordSheet) {
            KeywordEditSheet(keywords: $batchKeywordInput) { newKeywords in
                // apply keywords to all selected
                let keywordArray = newKeywords
                for id in selectedIDs {
                    if let index = appState.materials.firstIndex(where: { $0.id == id }) {
                        appState.materials[index].keywords = keywordArray
                    }
                }
                appState.storageService.saveMaterials(appState.materials)
                selectedIDs.removeAll()
            }
        }
    }

    private func exportSelected() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择导出目录"
        panel.begin { response in
            guard response == .OK, let dir = panel.url else { return }
            for id in selectedIDs {
                if let m = appState.materials.first(where: { $0.id == id }) {
                    if let src = m.localURL {
                        let dst = dir.appendingPathComponent(src.lastPathComponent)
                        do {
                            if FileManager.default.fileExists(atPath: dst.path) {
                                try FileManager.default.removeItem(at: dst)
                            }
                            try FileManager.default.copyItem(at: src, to: dst)
                        } catch {
                            print("导出失败: \(error)")
                        }
                    } else {
                        // write textual content
                        let filename = m.name.trimmingCharacters(in: .whitespacesAndNewlines) + ".txt"
                        let dst = dir.appendingPathComponent(filename)
                        do {
                            try m.content.write(to: dst, atomically: true, encoding: .utf8)
                        } catch {
                            print("导出文本失败: \(error)")
                        }
                    }
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }
    
    private func toggleFavorite(_ material: StudyMaterial) {
        if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
            appState.materials[index].isFavorite.toggle()
            appState.storageService.saveMaterials(appState.materials)
        }
    }
}

struct QuickPreviewView: View {
    let material: StudyMaterial

    var body: some View {
        Group {
            if material.type == .image, let url = material.localURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else if material.type == .pdf, let url = material.localURL, let doc = PDFDocument(url: url) {
                PDFKitRepresentedView(document: doc)
            } else {
                ScrollView {
                    Text(material.extractedText ?? material.content.prefix(200).description)
                        .padding()
                }
            }
        }
        .padding()
    }
}

// small wrapper to show PDFDocument inside SwiftUI
struct PDFKitRepresentedView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.document = document
    }
}

struct MaterialRowView: View {
    let material: StudyMaterial
    let searchText: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false
    @State private var thumbnail: NSImage? = nil
    @State private var showPreview: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: material.type.icon)
                        .font(.title2)
                        .foregroundColor(iconColor)
                }
            }
            .frame(width: 40, height: 40)
            .background(iconColor.opacity(0.08))
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    highlightedName()
                        .font(.headline)
                        .lineLimit(1)

                    if material.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }

                    if material.storageMode == .reference {
                        Image(systemName: "link")
                            .foregroundColor(.orange)
                            .font(.caption)
                            .help("关联文件：原文件移动将导致无法访问")
                    }
                }

                HStack(spacing: 8) {
                    Label(material.category.rawValue, systemImage: material.category.icon)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(material.displayFileSize)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text(material.displayDate)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let keywords = material.keywords, !keywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(keywords.prefix(5), id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: isSelected ? 1.5 : 0)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(isHovered ? 0.06 : 0)))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                isHovered = hovering
            }
            if hovering {
                // show preview after short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    if isHovered { showPreview = true }
                }
            } else {
                showPreview = false
            }
        }
        .onTapGesture {
            onSelect()
        }
        .popover(isPresented: $showPreview, arrowEdge: .trailing) {
            QuickPreviewView(material: material)
                .frame(width: 360, height: 260)
        }
        .onAppear {
            ThumbnailProvider.shared.thumbnail(for: material, size: CGSize(width: 64, height: 64)) { img in
                self.thumbnail = img
            }
        }
    }

    private func highlightedName() -> Text {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return Text(material.name) }
        let lowered = material.name.lowercased()
        let s = search.lowercased()
        if let range = lowered.range(of: s) {
            let prefix = String(material.name[..<range.lowerBound])
            let match = String(material.name[range])
            let suffix = String(material.name[range.upperBound...])
            return Text(prefix) + Text(match).foregroundColor(.accentColor) + Text(suffix)
        }
        return Text(material.name)
    }

    private var iconColor: Color {
        switch material.category {
        case .lecture: return .blue
        case .exam: return .red
        case .notes: return .green
        case .personalAnalysis: return .purple
        case .other: return .gray
        }
    }
}

// ...existing code...
