import SwiftUI

struct DiaryListView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @StateObject private var diaryService = DiaryService.shared
    @State private var showCreateSheet = false
    @State private var searchText = ""
    @State private var selectedDiary: DiaryEntry?
    @State private var filter: DiaryFilter = .all

    /// 「置顶」对应 `DiaryEntry.isPinned`；日记没有「收藏」概念。
    enum DiaryFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case pinned = "置顶"
        case encrypted = "加密"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filteredDiaries.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            .searchable(text: $searchText, prompt: "搜索日记...")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("筛选", selection: $filter) {
                        ForEach(DiaryFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                DiaryEditorView_iOS(entryID: nil)
                    .environmentObject(appState)
            }
            .sheet(item: $selectedDiary) { diary in
                DiaryEditorView_iOS(entryID: diary.id)
                    .environmentObject(appState)
            }
            .refreshable { /* 刷新 */ }
        }
        .navigationTitle("日记")
    }

    private var filteredDiaries: [DiaryEntry] {
        var result = diaryService.entries
        switch filter {
        case .pinned: result = result.filter { $0.isPinned }
        case .encrypted: result = result.filter { $0.isEncrypted }
        case .all: break
        }
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.content.localizedCaseInsensitiveContains(searchText) }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无日记", systemImage: "book")
        } description: {
            Text("记录生活点滴，留住美好记忆")
        } actions: {
            Button("新建日记") { showCreateSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var listContent: some View {
        List {
            ForEach(filteredDiaries) { diary in
                DiaryRow_iOS(diary: diary)
                    .onTapGesture { selectedDiary = diary }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            diaryService.deleteEntries([diary.id])
                        } label: { Label("删除", systemImage: "trash") }

                        Button { /* 编辑 */ } label: { Label("编辑", systemImage: "pencil") }
                            .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            diaryService.pinEntry(diary.id)
                        } label: {
                            Label(diary.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                        }
                        .tint(.orange)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct DiaryRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let diary: DiaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(diary.title.isEmpty ? "无标题" : diary.title)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)
                    .lineLimit(1)

                Spacer()

                if diary.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                }
                if diary.isEncrypted {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(appTheme.accent)
                }
            }

            Text(diary.content)
                .font(.subheadline)
                .foregroundStyle(appTheme.secondaryText)
                .lineLimit(2)

            HStack {
                Text(diary.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)

                // `DiaryEntry.category` 存的是分类名称，样式统一由主题给出。
                if !diary.category.isEmpty, diary.category != "默认" {
                    Text(diary.category)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(appTheme.accent.opacity(0.15))
                        .foregroundStyle(appTheme.accent)
                        .clipShape(Capsule())
                }

                if !diary.linkedMaterialIDs.isEmpty {
                    Text("关联 \(diary.linkedMaterialIDs.count) 份资料")
                        .font(.caption)
                        .foregroundStyle(appTheme.accent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct DiaryEditorView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @StateObject private var diaryService = DiaryService.shared
    let entryID: UUID?

    @State private var title = ""
    @State private var content = ""
    @State private var mood: Mood = .neutral
    @State private var isPinned = false
    @State private var isEncrypted = false
    @State private var categoryName = ""
    @State private var relatedMaterials: [StudyMaterial] = []
    @State private var showMaterialPicker = false

    enum Mood: String, CaseIterable {
        case happy = "开心", neutral = "平静", sad = "难过", anxious = "焦虑", excited = "兴奋", tired = "疲惫"
        var emoji: String {
            switch self {
            case .happy: return "😊"
            case .neutral: return "😐"
            case .sad: return "😢"
            case .anxious: return "😰"
            case .excited: return "🤩"
            case .tired: return "😴"
            }
        }
    }

    var isEditing: Bool { entryID != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("标题（可选）", text: $title)

                    Picker("心情", selection: $mood) {
                        ForEach(Mood.allCases, id: \.self) { m in
                            Text("\(m.emoji) \(m.rawValue)").tag(m)
                        }
                    }
                }

                Section("内容") {
                    TextEditor(text: $content)
                        .frame(minHeight: 200)
                }

                Section("设置") {
                    Toggle("置顶", isOn: $isPinned)
                    Toggle("加密", isOn: $isEncrypted)

                    Picker("分类", selection: $categoryName) {
                        Text("默认").tag("")
                        ForEach(diaryService.categories) { cat in
                            Text(cat.name).tag(cat.name)
                        }
                    }
                }

                Section("关联资料") {
                    if relatedMaterials.isEmpty {
                        Button("添加关联资料") { showMaterialPicker = true }
                    } else {
                        ForEach(relatedMaterials) { material in
                            HStack {
                                Text(material.name).lineLimit(1)
                                Spacer()
                                Button { relatedMaterials.removeAll { $0.id == material.id } } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.red)
                                }
                            }
                        }
                        Button("添加更多") { showMaterialPicker = true }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑日记" : "新建日记")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(content.isEmpty)
                }
            }
            .sheet(isPresented: $showMaterialPicker) {
                MaterialPickerView(selectedMaterials: $relatedMaterials)
                    .environmentObject(appState)
            }
            .onAppear { loadExisting() }
        }
    }

    private func loadExisting() {
        guard let id = entryID, let entry = diaryService.entries.first(where: { $0.id == id }) else { return }
        title = entry.title
        content = entry.content
        isPinned = entry.isPinned
        isEncrypted = entry.isEncrypted
        categoryName = entry.category
        relatedMaterials = entry.linkedMaterialIDs.compactMap { materialID in
            appState.materials.first { $0.id == materialID }
        }
    }

    private func save() {
        // 编辑时保留原始创建时间；新建则从现在开始。
        let existing = entryID.flatMap { id in diaryService.entries.first { $0.id == id } }
        let entry = DiaryEntry(
            id: entryID ?? UUID(),
            title: title,
            content: content,
            category: categoryName.isEmpty ? "默认" : categoryName,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            isPinned: isPinned,
            linkedMaterialIDs: relatedMaterials.map { $0.id },
            isEncrypted: isEncrypted
        )
        if existing != nil {
            _ = diaryService.updateEntry(entry)
        } else {
            _ = diaryService.addEntry(entry)
        }
        dismiss()
    }
}

struct MaterialPickerView: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMaterials: [StudyMaterial]

    var body: some View {
        NavigationStack {
            List {
                ForEach(appState.materials) { material in
                    Button {
                        if selectedMaterials.contains(where: { $0.id == material.id }) {
                            selectedMaterials.removeAll { $0.id == material.id }
                        } else {
                            selectedMaterials.append(material)
                        }
                    } label: {
                        HStack {
                            Image(systemName: material.type.icon)
                                .foregroundStyle(material.type.color)
                            Text(material.name)
                            Spacer()
                            if selectedMaterials.contains(where: { $0.id == material.id }) {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("选择关联资料")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// `MaterialType.icon` 已由 Shared/Models/StudyMaterial.swift 提供（两平台一致），
// 此处只补充仅 iOS 需要的 SwiftUI `Color` 映射。
extension MaterialType {
    var color: Color {
        switch self {
        case .pdf: return .red
        case .word: return .orange
        case .powerpoint: return .red
        case .image: return .blue
        case .text: return .green
        case .markdown: return .purple
        case .document: return .orange
        case .video: return .pink
        case .audio: return .cyan
        case .other: return .gray
        }
    }
}