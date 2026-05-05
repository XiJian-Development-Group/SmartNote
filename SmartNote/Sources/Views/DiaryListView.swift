import SwiftUI

struct DiaryListView: View {
    @StateObject private var diaryService = DiaryService.shared
    @State private var searchText = ""
    @State private var selectedDate: Date = Date()
    @State private var showDatePicker = false
    @State private var selectedEntries: Set<UUID> = []
    @State private var isSelectionMode = false
    @State private var showNewEntry = false
    @State private var showDeleteConfirmation = false
    @State private var entriesToDelete: [UUID] = []
    
    var filteredEntries: [DiaryEntry] {
        diaryService.searchEntries(query: searchText, date: showDatePicker ? selectedDate : nil)
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
        .sheet(isPresented: $showNewEntry) {
            DiaryEditorView(entry: nil)
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
                        isSelectionMode = true
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(.bordered)
                }
                
                Button {
                    showNewEntry = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索标题...", text: $searchText)
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
                        Text(showDatePicker ? "取消日期" : "按日期筛选")
                    }
                }
                .buttonStyle(.bordered)
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
            
            Text("点击上方按钮开始写日记")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private var diaryListContent: some View {
        List(filteredEntries) { entry in
            DiaryRowView(
                entry: entry,
                isSelected: selectedEntries.contains(entry.id),
                isSelectionMode: isSelectionMode,
                onTap: {
                    if isSelectionMode {
                        toggleSelection(entry.id)
                    } else {
                        showNewEntry = true
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
        .listStyle(.inset)
    }
    
    private func toggleSelection(_ id: UUID) {
        if selectedEntries.contains(id) {
            selectedEntries.remove(id)
        } else {
            selectedEntries.insert(id)
        }
    }
}

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
                }
                
                HStack {
                    Text(formatDate(entry.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Text("\(entry.wordCount) 字")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if !entry.category.isEmpty && entry.category != "默认" {
                    Text(entry.category)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button {
                onPin()
            } label: {
                Label(entry.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
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
