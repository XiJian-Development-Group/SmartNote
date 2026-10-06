import SwiftUI

/// iOS 待办清单界面。
///
/// 数据与提醒由 Shared 的 `TodoService` 负责（含本地提醒的调度与撤销），
/// 本视图只负责筛选、排序、编辑与快捷操作。
struct TodoListView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @StateObject private var service = TodoService.shared
    @State private var searchText = ""
    @State private var filter: TodoFilter = .active
    @State private var sortOption: TodoSortOption = .dueDate
    @State private var showsCreateSheet = false
    @State private var editingTodo: TodoItem?
    /// `TodoItem.category` 存的是分类名称，因此这里按名称筛选。
    @State private var selectedCategoryName: String?

    enum TodoFilter: String, CaseIterable, Identifiable {
        case active = "进行中"
        case completed = "已完成"
        case all = "全部"
        var id: String { rawValue }
    }

    enum TodoSortOption: String, CaseIterable, Identifiable {
        case dueDate = "截止时间"
        case priority = "优先级"
        case created = "创建时间"
        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if filteredTodos.isEmpty {
                ContentUnavailableView {
                    Label("暂无待办", systemImage: "checklist")
                } description: {
                    Text("点击右上角 + 添加第一个待办事项")
                } actions: {
                    Button("新建待办") { showsCreateSheet = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                listContent
            }
        }
        .navigationTitle("待办清单")
        .searchable(text: $searchText, prompt: "搜索待办")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("筛选", selection: $filter) {
                        ForEach(TodoFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("排序", selection: $sortOption) {
                        ForEach(TodoSortOption.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if !service.categories.isEmpty {
                        Picker("分类", selection: $selectedCategoryName) {
                            Text("全部分类").tag(String?.none)
                            ForEach(service.categories) { category in
                                Text(category.name).tag(String?.some(category.name))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsCreateSheet = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showsCreateSheet) {
            TodoEditor_iOS(existing: editingTodo)
        }
        .onAppear { service.loadAll() }
    }

    // MARK: - 列表

    private var filteredTodos: [TodoItem] {
        var result = service.items

        switch filter {
        case .active: result = result.filter { $0.status != .completed && $0.status != .archived }
        case .completed: result = result.filter { $0.status == .completed }
        case .all: break
        }

        if let selectedCategoryName {
            result = result.filter { $0.category == selectedCategoryName }
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                    || $0.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOption {
        case .dueDate:
            // 无截止时间的排在最后。
            result.sort { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
        case .priority:
            // `sortValue` 越小越紧急，因此降序排。
            result.sort { $0.priority.sortValue > $1.priority.sortValue }
        case .created:
            result.sort { $0.createdAt > $1.createdAt }
        }

        return result
    }

    private var listContent: some View {
        List {
            ForEach(filteredTodos) { todo in
                TodoRow_iOS(todo: todo)
                    .contentShape(Rectangle())
                    .onTapGesture { editingTodo = todo; showsCreateSheet = true }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            service.delete(todo)
                            appState.hapticFeedbackService.warning()
                        } label: { Label("删除", systemImage: "trash") }

                        Button { service.togglePin(todo) } label: {
                            Label(todo.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            service.toggleComplete(todo)
                            appState.hapticFeedbackService.success()
                        } label: {
                            Label(
                                todo.status == .completed ? "标记未完成" : "完成",
                                systemImage: todo.status == .completed ? "arrow.uturn.left" : "checkmark"
                            )
                        }
                        .tint(.green)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// 待办列表行。
struct TodoRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let todo: TodoItem

    private var isCompleted: Bool { todo.status == .completed }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: todo.status.iconName)
                .font(.title2)
                .foregroundStyle(isCompleted ? Color.green : appTheme.secondaryText)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if todo.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Text(todo.title)
                        .font(.headline)
                        .foregroundStyle(isCompleted ? appTheme.secondaryText : appTheme.primaryText)
                        .strikethrough(isCompleted)
                        .lineLimit(2)
                }

                if let dueDate = todo.dueDate {
                    HStack(spacing: 4) {
                        Image(systemName: dueDate < Date() && !isCompleted
                              ? "exclamationmark.circle.fill"
                              : "calendar")
                            .font(.caption)
                        Text(dueDate, style: .date)
                            .font(.caption)
                    }
                    .foregroundStyle(
                        dueDate < Date() && !isCompleted ? Color.red : appTheme.secondaryText
                    )
                }

                if !todo.category.isEmpty {
                    Text(todo.category)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(appTheme.accent.opacity(0.15))
                        .foregroundStyle(appTheme.accent)
                        .clipShape(Capsule())
                }
            }

            Spacer()

            if todo.priority != .medium {
                Image(systemName: TodoRow_iOS.priorityIcon(todo.priority))
                    .font(.caption)
                    .foregroundStyle(TodoRow_iOS.priorityColor(todo.priority))
            }
        }
        .padding(.vertical, 4)
    }

    static func priorityIcon(_ priority: TodoPriority) -> String {
        switch priority {
        case .urgent: return "exclamationmark.octagon.fill"
        case .high: return "exclamationmark.triangle.fill"
        case .medium: return "minus.circle.fill"
        case .low: return "arrow.down.circle.fill"
        }
    }

    static func priorityColor(_ priority: TodoPriority) -> Color {
        switch priority.color {
        case "red": return .red
        case "orange": return .orange
        case "blue": return .blue
        default: return .gray
        }
    }
}

/// 待办新增 / 编辑表单。
struct TodoEditor_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    let existing: TodoItem?

    @StateObject private var service = TodoService.shared
    @State private var title = ""
    @State private var details = ""
    @State private var priority: TodoPriority = .medium
    @State private var status: TodoStatus = .pending
    @State private var categoryName = ""
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var hasReminder = false
    @State private var reminderTime = Date()
    @State private var tagsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("标题", text: $title)
                    TextField("描述（可选）", text: $details, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("时间") {
                    Toggle("设置截止日期", isOn: $hasDueDate.animation())
                    if hasDueDate {
                        DatePicker("截止时间", selection: $dueDate)
                    }
                    Toggle("设置提醒", isOn: $hasReminder.animation())
                    if hasReminder {
                        DatePicker("提醒时间", selection: $reminderTime, displayedComponents: [.hourAndMinute])
                    }
                }

                Section("属性") {
                    Picker("优先级", selection: $priority) {
                        ForEach(TodoPriority.allCases) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    Picker("状态", selection: $status) {
                        ForEach(TodoStatus.allCases) { state in
                            Label(state.displayName, systemImage: state.iconName)
                                .tag(state)
                        }
                    }
                }

                Section("分类与标签") {
                    Picker("分类", selection: $categoryName) {
                        Text("默认").tag("")
                        ForEach(service.categories) { category in
                            Text(category.name).tag(category.name)
                        }
                    }
                    TextField("标签，逗号分隔", text: $tagsText)
                }

                if existing != nil {
                    Section {
                        Button(role: .destructive) {
                            if let existing { service.delete(existing) }
                            dismiss()
                        } label: {
                            Text("删除待办").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建待办" : "编辑待办")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        service.loadAll()
        guard let existing else { return }
        title = existing.title
        details = existing.description
        priority = existing.priority
        status = existing.status
        categoryName = existing.category
        if let dueDate = existing.dueDate {
            hasDueDate = true
            self.dueDate = dueDate
        }
        if let reminderTime = existing.reminderTime {
            hasReminder = true
            self.reminderTime = reminderTime
        }
        tagsText = existing.tags.joined(separator: ", ")
    }

    private func commit() {
        var item = existing ?? TodoItem(title: title.trimmingCharacters(in: .whitespaces))

        item.title = title.trimmingCharacters(in: .whitespaces)
        item.description = details
        item.priority = priority
        item.status = status
        item.category = categoryName.isEmpty ? "默认" : categoryName
        item.dueDate = hasDueDate ? dueDate : nil
        item.reminderTime = hasReminder ? reminderTime : nil
        item.tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if existing == nil {
            service.add(item)
        } else {
            service.update(item)
        }

        // 提醒需要单独调度：模型只保存时间，是否真的挂起由服务判断权限。
        Task {
            if hasReminder {
                _ = await service.scheduleReminder(for: item)
            }
        }
        appState.hapticFeedbackService.success()
        dismiss()
    }
}