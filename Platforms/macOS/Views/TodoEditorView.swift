import SwiftUI

struct TodoEditorView: View {
    @StateObject private var todoService = TodoService.shared
    @Environment(\.dismiss) var dismiss
    
    let itemID: UUID?
    let onSave: (TodoItem) -> Void
    
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var category: String = "默认"
    @State private var priority: TodoPriority = .medium
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var hasReminder: Bool = false
    @State private var reminderTime: Date? = Date()
    @State private var reminderOffset: Int = 0
    @State private var isPinned: Bool = false
    @State private var tagsText: String = ""
    @State private var status: TodoStatus = .pending
    @State private var loaded = false
    @State private var reminderIsScheduled = false
    @State private var isSaving = false
    @State private var showReminderError = false
    @State private var reminderErrorMessage = ""
    
    private var isNewItem: Bool { itemID == nil }
    
    init(item: TodoItem?, onSave: @escaping (TodoItem) -> Void) {
        self.itemID = item?.id
        self.onSave = onSave
    }
    
    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            editorContent
        }
        .frame(width: 700, height: 720)
        .task(id: itemID) {
            loadFromItem()
        }
        .alert("待办提醒", isPresented: $showReminderError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(reminderErrorMessage)
        }
    }
    
    private func loadFromItem() {
        guard let id = itemID, let item = todoService.items.first(where: { $0.id == id }) else {
            // 新建模式
            if !loaded {
                hasReminder = false
                reminderIsScheduled = false
                loaded = true
            }
            return
        }
        title = item.title
        description = item.description
        category = item.category
        priority = item.priority
        hasDueDate = item.dueDate != nil
        dueDate = item.dueDate ?? Date()
        hasReminder = item.reminderTime != nil
        reminderTime = item.reminderTime
        reminderIsScheduled = hasReminder
        // reminderOffset = item.reminderOffset
        isPinned = item.isPinned
        tagsText = item.tags.joined(separator: ", ")
        status = item.status
        loaded = true
    }
    
    // MARK: - 顶部
    
    private var editorHeader: some View {
        HStack {
            Button("取消") { dismiss() }
                .disabled(isSaving)
            Spacer()
            Text(isNewItem ? "新建待办" : "编辑待办")
                .font(.headline)
            Spacer()
            Button("保存") {
                saveItem()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(title.isEmpty || isSaving)
        }
        .padding()
    }
    
    // MARK: - 内容
    
    private var editorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleSection
                descriptionSection
                categoryAndPrioritySection
                dateSection
                reminderSection
                tagsSection
                if !isNewItem {
                    statisticsSection
                }
            }
            .padding()
        }
    }
    
    // MARK: - 标题
    
    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标题")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField("请输入待办标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
        }
    }
    
    // MARK: - 描述
    
    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("描述")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextEditor(text: $description)
                .font(.body)
                .frame(height: 100)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }
    
    // MARK: - 分类与优先级
    
    private var categoryAndPrioritySection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("分类")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("分类", selection: $category) {
                    ForEach(todoService.categories) { cat in
                        Text(cat.name).tag(cat.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("优先级")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("优先级", selection: $priority) {
                    ForEach(TodoPriority.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("状态")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Picker("状态", selection: $status) {
                    ForEach(TodoStatus.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }
    
    // MARK: - 日期
    
    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("设置截止日期", isOn: $hasDueDate)
            
            if hasDueDate {
                HStack {
                    DatePicker("日期", selection: $dueDate, displayedComponents: [.date])
                        .labelsHidden()
                    
                    DatePicker("时间", selection: $dueDate, displayedComponents: [.hourAndMinute])
                        .labelsHidden()
                    
                    Spacer()
                    
                    Button {
                        hasDueDate = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading)
            }
        }
    }
    
    // MARK: - 提醒
    
    private var reminderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("设置提醒", isOn: Binding(
                get: { hasReminder },
                set: { enabled in
                    hasReminder = enabled
                    if enabled {
                        if reminderTime == nil {
                            reminderTime = dueDate
                        }
                        reminderIsScheduled = false
                    } else {
                        reminderIsScheduled = false
                    }
                }
            ))
                .disabled(!hasDueDate)
                .help(hasDueDate ? "" : "请先设置截止日期")
            
            if hasReminder && hasDueDate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Picker("提前", selection: $reminderOffset) {
                            Text("准时").tag(0)
                            Text("提前5分钟").tag(5)
                            Text("提前15分钟").tag(15)
                            Text("提前30分钟").tag(30)
                            Text("提前1小时").tag(60)
                            Text("提前1天").tag(1440)
                            Text("自定义").tag(-1)
                        }
                        .onChange(of: reminderOffset) { newValue in
                            reminderIsScheduled = false
                            if newValue >= 0 {
                                reminderTime = Calendar.current.date(byAdding: .minute, value: -newValue, to: dueDate) ?? dueDate
                            }
                        }
                        
                        if reminderOffset == -1 {
                            DatePicker("提醒时间", selection: Binding(
                                get: { reminderTime ?? dueDate },
                                set: {
                                    reminderTime = $0
                                    reminderIsScheduled = false
                                }
                            ))
                                .labelsHidden()
                        }
                        
                        Spacer()
                        
                        Button {
                            hasReminder = false
                            reminderIsScheduled = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Text(reminderDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(reminderStatusText)
                        .font(.caption)
                        .foregroundColor(reminderIsScheduled ? .green : .secondary)
                }
                .padding(.leading)
            }
        }
    }
    
    private var reminderDescription: String {
        guard let reminderTime else {
            return "尚未设置提醒时间"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return "将于 \(formatter.string(from: reminderTime)) 提醒"
    }

    private var reminderStatusText: String {
        if reminderIsScheduled {
            return "提醒已开启"
        }
        return "保存后将验证并开启提醒"
    }
    
    // MARK: - 标签
    
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签（用空格或逗号分隔）")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextField("例如：urgent 期末", text: $tagsText)
                .textFieldStyle(.roundedBorder)
            
            Toggle("置顶", isOn: $isPinned)
        }
    }
    
    // MARK: - 统计（仅编辑模式）
    
    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("统计信息")
                .font(.headline)
            
            HStack(spacing: 16) {
                StatBox(
                    icon: "timer",
                    title: "番茄钟时长",
                    value: formatTime(currentItem?.totalFocusedSeconds ?? 0),
                    color: .orange
                )
                StatBox(
                    icon: "clock",
                    title: "累计处理",
                    value: formatTime(currentItem?.totalElapsedSeconds ?? 0),
                    color: .blue
                )
                StatBox(
                    icon: "calendar",
                    title: "存在时长",
                    value: formatTime(currentItem?.totalCompletionSeconds ?? 0),
                    color: .green
                )
            }
            
            if let currentItem = currentItem, !currentItem.pomodoroSessions.isEmpty {
                Text("番茄钟会话数：\(currentItem.pomodoroSessions.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
    
    // MARK: - 辅助方法
    
    private var currentItem: TodoItem? {
        guard let id = itemID else { return nil }
        return todoService.items.first { $0.id == id }
    }
    
    private func saveItem() {
        guard !isSaving else { return }

        let saved = makeItem()
        isSaving = true

        Task { @MainActor in
            if saved.reminderTime != nil {
                // 这是用户主动保存并开启/修改提醒的路径；启动和后台恢复不会
                // 经过这里，因此只在这里请求通知权限。
                _ = await NotificationService.shared.requestAuthorization()
            }

            // scheduleReminder 才是系统 add 的真实结果；本地开关不能代替它。
            let result = await todoService.scheduleReminder(for: saved)
            switch result {
            case .success:
                hasReminder = saved.reminderTime != nil
                reminderIsScheduled = saved.reminderTime != nil
                onSave(saved)
                isSaving = false
                dismiss()
            case .failure(let error):
                // 失败时仍保存其它编辑内容，但绝不把一个没有排上的提醒写回去。
                var itemWithoutReminder = saved
                itemWithoutReminder.reminderTime = nil
                hasReminder = false
                reminderTime = nil
                reminderIsScheduled = false
                onSave(itemWithoutReminder)
                isSaving = false
                reminderErrorMessage = error.localizedDescription
                showReminderError = true
            }
        }
    }

    private func makeItem() -> TodoItem {
        let tags = tagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var item: TodoItem
        if let id = itemID, let existing = todoService.items.first(where: { $0.id == id }) {
            item = existing
        } else {
            item = TodoItem()
        }

        item.title = title
        item.description = description
        item.category = category
        item.priority = priority
        item.status = status
        item.isPinned = isPinned
        item.dueDate = hasDueDate ? dueDate : nil
        let shouldScheduleReminder = hasDueDate && hasReminder && status != .completed
        item.reminderTime = shouldScheduleReminder ? reminderTime : nil
        // item.reminderOffset = reminderOffset
        item.tags = tags
        item.updatedAt = Date()

        if status == .completed && item.completedAt == nil {
            item.completedAt = Date()
        } else if status != .completed {
            item.completedAt = nil
        }

        return item
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else if Int(seconds) > 0 {
            return "\(Int(seconds))s"
        } else {
            return "0"
        }
    }
}

struct StatBox: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(6)
    }
}
