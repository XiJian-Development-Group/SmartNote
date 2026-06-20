import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DiaryListView: View {
    @StateObject private var diaryService = DiaryService.shared
    @Environment(\.openWindow) private var openWindow
    @State private var searchText = ""
    @State private var selectedDate: Date = Date()
    @State private var showDatePicker = false
    @State private var selectedEntries: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showDeleteConfirmation = false
    @State private var entriesToDelete: [UUID] = []
    
    // 分类筛选
    @State private var selectedCategory: String? = nil  // nil = 全部
    @State private var showCategoryFilter = false
    
    // 统计视图
    @State private var showStatistics = false
    
    var filteredEntries: [DiaryEntry] {
        var results = diaryService.entries
        
        // 分类筛选
        if let cat = selectedCategory {
            results = results.filter { $0.category == cat }
        }
        
        // 日期筛选
        if showDatePicker {
            let calendar = Calendar.current
            results = results.filter { calendar.isDate($0.createdAt, inSameDayAs: selectedDate) }
        }
        
        // 搜索
        if !searchText.isEmpty {
            results = results.filter { 
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.content.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return results.sorted { entry1, entry2 in
            if entry1.isPinned != entry2.isPinned {
                return entry1.isPinned
            }
            return entry1.createdAt > entry2.createdAt
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if filteredEntries.isEmpty {
                emptyStateView
            } else {
                diaryListContent
            }
        }
        .sheet(isPresented: $showStatistics) {
            DiaryStatisticsView()
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                diaryService.deleteEntries(entriesToDelete)
                selectedEntries.removeAll()
                isSelectionMode = false
            }
        } message: {
            Text("确定要删除选中的 \(entriesToDelete.count) 篇日记吗？此操作不可恢复。")
        }
    }
    
    private var headerView: some View {
        VStack(spacing: 12) {
            HStack {
                Text("日记")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                if isSelectionMode {
                    Text("\(selectedEntries.count) 已选")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Button {
                        showDeleteConfirmation = true
                        entriesToDelete = Array(selectedEntries)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(selectedEntries.isEmpty)
                    
                    Button("取消") {
                        isSelectionMode = false
                        selectedEntries.removeAll()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        showStatistics = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .buttonStyle(.bordered)
                    .help("日记统计")
                    
                    Button {
                        isSelectionMode = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
                
                Button {
                    openWindow(id: "diary-editor")
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            
            // 搜索栏
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索标题或内容...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
                
                Button {
                    showDatePicker.toggle()
                } label: {
                    HStack {
                        Image(systemName: "calendar")
                        Text(showDatePicker ? "取消日期" : "日期")
                    }
                }
                .buttonStyle(.bordered)
                .background(showDatePicker ? Color.accentColor.opacity(0.2) : Color.clear)
            }
            
            // 分类筛选
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    CategoryFilterChip(
                        name: "全部",
                        color: Color.gray,
                        isSelected: selectedCategory == nil,
                        action: { selectedCategory = nil }
                    )
                    
                    ForEach(diaryService.categories) { cat in
                        CategoryFilterChip(
                            name: cat.name,
                            color: Color(hex: cat.color) ?? .blue,
                            isSelected: selectedCategory == cat.name,
                            action: { selectedCategory = cat.name }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
            
            if showDatePicker {
                DatePicker("选择日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
            }
        }
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "book.closed")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("还没有日记")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("点击右上角 + 开始写日记")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private var diaryListContent: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredEntries) { entry in
                    DiaryRowView(
                        entry: entry,
                        isSelected: selectedEntries.contains(entry.id),
                        isSelectionMode: isSelectionMode,
                        onTap: {
                            if isSelectionMode {
                                toggleSelection(entry.id)
                            } else {
                                openWindow(id: "diary-editor", value: entry.id)
                            }
                        },
                        onPin: {
                            diaryService.pinEntry(entry.id)
                        },
                        onLongPress: {
                            isSelectionMode = true
                            selectedEntries.insert(entry.id)
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
    
    private func toggleSelection(_ id: UUID) {
        if selectedEntries.contains(id) {
            selectedEntries.remove(id)
        } else {
            selectedEntries.insert(id)
        }
    }
}

// MARK: - 分类筛选 Chip

struct CategoryFilterChip: View {
    let name: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.25) : Color(nsColor: .controlBackgroundColor))
            .foregroundColor(isSelected ? color : .primary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 日记行

struct DiaryRowView: View {
    let entry: DiaryEntry
    let isSelected: Bool
    let isSelectionMode: Bool
    let onTap: () -> Void
    let onPin: () -> Void
    let onLongPress: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .font(.title3)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    
                    Text(entry.title.isEmpty ? "无标题" : entry.title)
                        .font(.headline)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // 标识
                    if !entry.imagePaths.isEmpty {
                        Image(systemName: "photo")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                    if entry.whiteboardID != nil {
                        Image(systemName: "scribble.variable")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                }
                
                HStack(spacing: 8) {
                    Text(formatDate(entry.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text("\(entry.chineseWordCount) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if !entry.category.isEmpty {
                        Text(entry.category)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }
            
            Spacer()
            
            if !isSelectionMode {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.5, perform: onLongPress)
        .contextMenu {
            Button {
                onPin()
            } label: {
                Label(entry.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
            }
            Button {
                onTap()
            } label: {
                Label("编辑", systemImage: "pencil")
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
