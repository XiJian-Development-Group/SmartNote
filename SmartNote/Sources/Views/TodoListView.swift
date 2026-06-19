import SwiftUI

struct TodoListView: View {
    @StateObject private var todoService = TodoService.shared
    @State private var searchText: String = ""
    @State private var selectedStatus: TodoStatus? = nil
    @State private var selectedCategory: String? = nil
    @State private var showEditor = false
    @State private var editingItem: TodoItem? = nil
    @State private var showStatistics = false
    @State private var showCategoryManager = false
    
    @State private var isSelectionMode = false
    @State private var selectedItems: Set<UUID> = []
    @State private var showDeleteConfirmation = false
    @State private var showBatchCompleteConfirmation = false
    
    private var filteredItems: [TodoItem] {
        todoService.searchItems(query: searchText, status: selectedStatus, category: selectedCategory)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            filterBar
            
            if filteredItems.isEmpty {
                emptyState
            } else {
                todoListContent
            }
        }
        .navigationTitle("待办清单")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedItems.removeAll()
                    }
                } label: {
                    Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(isSelectionMode ? "退出选择" : "批量选择")
                .keyboardShortcut("a", modifiers: [.command, .shift])
                
                Button {
                    showStatistics = true
                } label: {
                    Image(systemName: "chart.bar.fill")
                }
                .help("统计")
                
                Button {
                    openNewEditor()
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建待办 (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .searchable(text: $searchText, prompt: "搜索标题、描述、标签")
        .sheet(isPresented: $showEditor, onDismiss: {
            editingItem = nil
        }) {
            TodoEditorView(
                item: editingItem,
                onSave: { newItem in
                    if todoService.items.contains(where: { $0.id == newItem.id }) {
                        todoService.update(newItem)
                    } else {
                        todoService.add(newItem)
                    }
                }
            )
        }
        .sheet(isPresented: $showStatistics) {
            TodoStatisticsView()
        }
        .sheet(isPresented: $showCategoryManager) {
            TodoCategoryManagerView()
        }
        .alert("确认删除", isPresented: $showDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                let itemsToDelete = todoService.items.filter { selectedItems.contains($0.id) }
                todoService.delete(itemsToDelete)
                selectedItems.removeAll()
                isSelectionMode = false
            }
        } message: {
            Text("确定要删除选中的 \(selectedItems.count) 个待办吗？此操作不可恢复。")
        }
        .alert("标记完成", isPresented: $showBatchCompleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("完成", role: .none) {
                for id in selectedItems {
                    if let item = todoService.items.first(where: { $0.id == id }) {
                        var updated = item
                        if updated.status != .completed {
                            updated.status = .completed
                            updated.completedAt = Date()
                            updated.updatedAt = Date()
                            todoService.update(updated)
                        }
                    }
                }
                selectedItems.removeAll()
                isSelectionMode = false
            }
        } message: {
            Text("将选中的 \(selectedItems.count) 个待办标记为完成？")
        }
    }
    
    // MARK: - 操作
    
    private func openNewEditor() {
        editingItem = nil
        // 等待下一帧让 SwiftUI 捕获新值
        DispatchQueue.main.async {
            showEditor = true
        }
    }
    
    private func openEditEditor(for item: TodoItem) {
        editingItem = item
        DispatchQueue.main.async {
            showEditor = true
        }
    }
    
    // MARK: - 筛选栏
    
    private var filterBar: some View {
        VStack(spacing: 8) {
            if isSelectionMode {
                selectionBar
            }
            
            HStack(spacing: 8) {
                Menu {
                    Button {
                        selectedStatus = nil
                    } label: {
                        Label("全部", systemImage: selectedStatus == nil ? "checkmark" : "")
                    }
                    ForEach(TodoStatus.allCases) { status in
                        Button {
                            selectedStatus = status
                        } label: {
                            HStack {
                                Text(status.displayName)
                                if selectedStatus == status {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(selectedStatus?.displayName ?? "全部")
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                
                Menu {
                    Button {
                        selectedCategory = nil
                    } label: {
                        Label("全部分类", systemImage: selectedCategory == nil ? "checkmark" : "")
                    }
                    ForEach(todoService.categories) { category in
                        Button {
                            selectedCategory = category.name
                        } label: {
                            HStack {
                                Text(category.name)
                                if selectedCategory == category.name {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        showCategoryManager = true
                    } label: {
                        Label("管理分类", systemImage: "folder.badge.gearshape")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(selectedCategory ?? "全部分类")
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                
                Spacer()
                
                Text("\(filteredItems.count) 项")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - 批量选择栏
    
    private var selectionBar: some View {
        HStack(spacing: 12) {
            Button {
                if selectedItems.count == filteredItems.count {
                    selectedItems.removeAll()
                } else {
                    selectedItems = Set(filteredItems.map { $0.id })
                }
            } label: {
                Text(selectedItems.count == filteredItems.count ? "取消全选" : "全选")
                    .font(.system(size: 12))
            }
            
            Spacer()
            
            Text("已选 \(selectedItems.count) 项")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button {
                showBatchCompleteConfirmation = true
            } label: {
                Label("完成", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
            }
            .disabled(selectedItems.isEmpty)
            
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("删除", systemImage: "trash")
                    .font(.system(size: 12))
            }
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
    }
    
    // MARK: - 列表内容
    
    private var todoListContent: some View {
        // 使用 ScrollView + LazyVStack 而非 List，避免 selection binding 与 onTap 冲突
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(filteredItems) { item in
                    TodoRowView(
                        item: item,
                        isSelectionMode: isSelectionMode,
                        isSelected: selectedItems.contains(item.id),
                        onToggle: {
                            todoService.toggleComplete(item)
                        },
                        onTogglePin: {
                            todoService.togglePin(item)
                        },
                        onEdit: {
                            openEditEditor(for: item)
                        },
                        onStartPomodoro: {
                            todoService.startPomodoroForTodo(item)
                        },
                        onDelete: {
                            todoService.delete(item)
                        },
                        onToggleSelection: {
                            if selectedItems.contains(item.id) {
                                selectedItems.remove(item.id)
                            } else {
                                selectedItems.insert(item.id)
                            }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    // MARK: - 空状态
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text(searchText.isEmpty ? "暂无待办" : "未找到匹配的待办")
                .font(.title3)
                .foregroundColor(.secondary)
            if searchText.isEmpty {
                Button {
                    openNewEditor()
                } label: {
                    Label("添加待办", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 待办行视图

struct TodoRowView: View {
    let item: TodoItem
    let isSelectionMode: Bool
    let isSelected: Bool
    let onToggle: () -> Void
    let onTogglePin: () -> Void
    let onEdit: () -> Void
    let onStartPomodoro: () -> Void
    let onDelete: () -> Void
    let onToggleSelection: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // 完成状态圆圈
            Button(action: handleCheckButton) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : (item.status == .completed ? "checkmark.circle.fill" : "circle"))
                    .foregroundColor(isSelected ? .accentColor : (item.status == .completed ? .green : .secondary))
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .help(isSelectionMode ? (isSelected ? "取消选择" : "选择") : (item.status == .completed ? "标记为未完成" : "标记为完成"))
            
            // 主体内容（点击编辑）
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .strikethrough(item.status == .completed, color: .secondary)
                        .foregroundColor(item.status == .completed ? .secondary : .primary)
                        .lineLimit(1)
                    
                    if !item.tags.isEmpty {
                        ForEach(item.tags.prefix(2), id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.system(size: 10))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                }
                
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                HStack(spacing: 8) {
                    Label(item.category, systemImage: "folder")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Text(item.priority.displayName)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(priorityColor(item.priority).opacity(0.2))
                        .foregroundColor(priorityColor(item.priority))
                        .cornerRadius(3)
                    
                    Text(item.dueDateText())
                        .font(.system(size: 10))
                        .foregroundColor(item.isOverdue ? .red : .secondary)
                    
                    if item.totalFocusedSeconds > 0 {
                        Label(formatTime(item.totalFocusedSeconds), systemImage: "timer")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectionMode {
                    onToggleSelection()
                } else {
                    onEdit()
                }
            }
            
            // 右侧操作区
            if !isSelectionMode {
                HStack(spacing: 8) {
                    // 番茄钟快捷启动
                    Button(action: onStartPomodoro) {
                        Image(systemName: "timer")
                            .foregroundColor(item.status == .inProgress ? .orange : .secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help("启动番茄钟")
                    
                    // 置顶
                    Button(action: onTogglePin) {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "取消置顶" : "置顶")
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !isSelectionMode {
                onEdit()
            }
        }
        .contextMenu {
            if !isSelectionMode {
                Button {
                    onToggle()
                } label: {
                    Label(item.status == .completed ? "标记为未完成" : "标记为完成",
                          systemImage: item.status == .completed ? "circle" : "checkmark.circle")
                }
                
                Button {
                    onTogglePin()
                } label: {
                    Label(item.isPinned ? "取消置顶" : "置顶",
                          systemImage: item.isPinned ? "pin.slash" : "pin")
                }
                
                Button {
                    onStartPomodoro()
                } label: {
                    Label("开始番茄钟", systemImage: "timer")
                }
                
                Button {
                    onEdit()
                } label: {
                    Label("编辑", systemImage: "pencil")
                }
                
                Divider()
                
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } else {
                Button {
                    onToggleSelection()
                } label: {
                    Label(isSelected ? "取消选择" : "选择",
                          systemImage: isSelected ? "circle" : "checkmark.circle")
                }
            }
        }
    }
    
    private func handleCheckButton() {
        if isSelectionMode {
            onToggleSelection()
        } else {
            onToggle()
        }
    }
    
    private func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority {
        case .low: return .gray
        case .medium: return .blue
        case .high: return .orange
        case .urgent: return .red
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(Int(seconds))s"
        }
    }
}

// MARK: - 分类管理视图

struct TodoCategoryManagerView: View {
    @StateObject private var todoService = TodoService.shared
    @Environment(\.dismiss) var dismiss
    @State private var newCategoryName = ""
    @State private var newCategoryColor = "blue"
    @State private var newCategoryIcon = "folder"
    
    let colorOptions = ["blue", "green", "orange", "red", "purple", "pink", "yellow", "gray"]
    let iconOptions = ["folder", "book", "briefcase", "house", "heart", "star", "lightbulb", "graduationcap"]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("分类管理")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding()
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("添加分类")
                    .font(.headline)
                
                HStack {
                    TextField("分类名称", text: $newCategoryName)
                        .textFieldStyle(.roundedBorder)
                    
                    Picker("颜色", selection: $newCategoryColor) {
                        ForEach(colorOptions, id: \.self) { color in
                            Text(color).tag(color)
                        }
                    }
                    .frame(width: 100)
                    
                    Picker("图标", selection: $newCategoryIcon) {
                        ForEach(iconOptions, id: \.self) { icon in
                            Text(icon).tag(icon)
                        }
                    }
                    .frame(width: 100)
                    
                    Button {
                        if !newCategoryName.isEmpty {
                            todoService.addCategory(name: newCategoryName, color: newCategoryColor, icon: newCategoryIcon)
                            newCategoryName = ""
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newCategoryName.isEmpty)
                }
            }
            .padding()
            
            Divider()
            
            List {
                ForEach(todoService.categories) { category in
                    HStack {
                        Image(systemName: category.icon)
                            .foregroundColor(colorFromString(category.color))
                        Text(category.name)
                        Spacer()
                        Text("\(todoService.items.filter { $0.category == category.name }.count) 项")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            todoService.deleteCategory(category)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .frame(width: 600, height: 500)
    }
    
    private func colorFromString(_ colorName: String) -> Color {
        switch colorName {
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "red": return .red
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        default: return .gray
        }
    }
}
