import SwiftUI

struct MaterialsListView: View {
    @EnvironmentObject var appState: AppState
    @State private var isEditing = false
    @State private var editingMaterial: StudyMaterial?
    @State private var showCreateMaterial = false
    
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
        List(displayedMaterials) { material in
            MaterialRowView(material: material)
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
                    editingMaterial = material
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
    
    private func toggleFavorite(_ material: StudyMaterial) {
        if let index = appState.materials.firstIndex(where: { $0.id == material.id }) {
            appState.materials[index].isFavorite.toggle()
            appState.storageService.saveMaterials(appState.materials)
        }
    }
}

struct MaterialRowView: View {
    let material: StudyMaterial
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: material.type.icon)
                .font(.title2)
                .foregroundColor(iconColor)
                .frame(width: 40, height: 40)
                .background(iconColor.opacity(0.1))
                .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(material.name)
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
            
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
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
