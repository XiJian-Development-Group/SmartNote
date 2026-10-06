import SwiftUI
import Charts

struct PomodoroView: View {
    @StateObject private var timer = PomodoroTimer.shared
    @StateObject private var stats = StudyStatisticsService.shared
    @StateObject private var todoService = TodoService.shared
    @State private var selectedSubj: String = "通用"
    @State private var showSettings = false
    @State private var showTodoPicker = false
    @State private var showTodoList = false
    
    /// 当前番茄钟关联的待办（优先取番茄钟的linkedTodoID，否则取subjName）
    private var currentTodoItem: TodoItem? {
        if let id = timer.linkedTodoID {
            return todoService.items.first { $0.id == id }
        }
        if let title = timer.linkedTodoTitle {
            return todoService.items.first { $0.title == title }
        }
        return nil
    }
    
    /// 待筛选：未完成的待办，按状态、置顶、优先级排序
    private var availableTodos: [TodoItem] {
        todoService.items
            .filter { $0.status != .completed && $0.status != .archived }
            .sorted { item1, item2 in
                if item1.isPinned != item2.isPinned { return item1.isPinned }
                if item1.priority.sortValue != item2.priority.sortValue {
                    return item1.priority.sortValue < item2.priority.sortValue
                }
                if let d1 = item1.dueDate, let d2 = item2.dueDate { return d1 < d2 }
                return item1.createdAt > item2.createdAt
            }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                timerDisplay
                currentTaskCard
                timerControls
                Divider()
                statisticsView
                linkedTodoList
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showSettings) {
            pomodoroSettings
        }
        .sheet(isPresented: $showTodoPicker) {
            TodoPickerSheet(
                todos: availableTodos,
                onSelect: { selectedTodo in
                    timer.startForTodo(todoID: selectedTodo.id, todoTitle: selectedTodo.title)
                    showTodoPicker = false
                }
            )
        }
    }
    
    // MARK: - 计时器显示
    
    private var timerDisplay: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 12)
                    .frame(width: 200, height: 200)
                
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(timerColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                
                VStack(spacing: 4) {
                    Text(timer.currentPhase.displayName)
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text(timeString)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    
                    if timer.isRunning {
                        Text("\(timer.sessionsCompleted) 个番茄完成")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.top, 12)
    }
    
    // MARK: - 当前关联任务卡片
    
    @ViewBuilder
    private var currentTaskCard: some View {
        if let currentT = currentTodoItem {
            HStack(spacing: 12) {
                Image(systemName: "checklist.checked")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前任务")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(currentT.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                }
                
                Spacer()
                
                Button {
                    timer.unlinkTodo()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("解除关联")
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(8)
        } else if !timer.isRunning {
            // 未运行时显示选择提示
            HStack(spacing: 8) {
                Image(systemName: "link.badge.plus")
                    .foregroundColor(.secondary)
                Text("选择一个待办开始专注")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }
    
    // MARK: - 计时器控制
    
    private var timerControls: some View {
        HStack(spacing: 12) {
            if timer.isRunning {
                Button {
                    timer.pause()
                } label: {
                    Label(timer.isPaused ? "继续" : "暂停", systemImage: timer.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button {
                    timer.stop()
                } label: {
                    Label("停止", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.large)
            } else {
                // Picker("科目", selection: $selectedSubj) {
                //     Text("通用").tag("通用")
                //     ForEach(Array(Set(stats.subjectStats.keys)).sorted(), id: \.self) { subj in
                //         Text(subj).tag(subj)
                //     }
                // }
                // .frame(width: 110)
                
                Button {
                    showTodoPicker = true
                } label: {
                    Label("选择待办", systemImage: "checklist")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button {
                    timer.start(subject: selectedSubj)
                } label: {
                    Label("开始专注", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
    
    // MARK: - 学习统计
    
    private var statisticsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("学习统计")
                .font(.headline)
            
            HStack(spacing: 16) {
                statCard(title: "今日", value: formatDuration(stats.todayDuration), icon: "sun.max.fill")
                statCard(title: "本周", value: formatDuration(stats.weekDuration), icon: "calendar")
                statCard(title: "完成率", value: String(format: "%.0f%%", stats.completionRate), icon: "checkmark.circle.fill")
            }
            
            if !stats.subjectStats.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("科目分布")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Chart {
                        ForEach(Array(stats.subjectStats.keys.sorted().prefix(5)), id: \.self) { s in
                            BarMark(
                                x: .value("时长", stats.subjectStats[s] ?? 0),
                                y: .value("科目", s)
                            )
                            .foregroundStyle(Color.accentColor.gradient)
                        }
                    }
                    .frame(height: 150)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
    
    // MARK: - 关联的待办快捷列表
    
    @ViewBuilder
    private var linkedTodoList: some View {
        if !availableTodos.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("待办事项")
                        .font(.headline)
                    Spacer()
                    Text("点击启动专注")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                ForEach(Array(availableTodos.prefix(3)), id: \.id) { todoItem in
                    LinkedTodoRow(todoItem: todoItem, onStart: {
                        timer.startForTodo(todoID: todoItem.id, todoTitle: todoItem.title)
                    }, dueDateText: dueDateText)
                }
                
                if availableTodos.count > 3 {
                    Button {
                        showTodoPicker = true
                    } label: {
                        Text("查看更多 (\(availableTodos.count))")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .cornerRadius(12)
        }
    }
    
    // MARK: - 辅助视图
    
    private func statCard(title: String, value: String, icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
        .cornerRadius(8)
    }
    
    private var pomodoroSettings: some View {
        VStack(spacing: 20) {
            Text("番茄钟设置")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 12) {
                Stepper("专注时长: \(timer.workDuration) 分钟", value: $timer.workDuration, in: 5...60, step: 5)
                Stepper("短休息: \(timer.shortBreakDuration) 分钟", value: $timer.shortBreakDuration, in: 1...15, step: 1)
                Stepper("长休息: \(timer.longBreakDuration) 分钟", value: $timer.longBreakDuration, in: 5...30, step: 5)
                Toggle("专注模式", isOn: $timer.isFocusModeEnabled)
            }
            .padding()
            
            Button("保存") {
                timer.setDurations(work: timer.workDuration, shortBreak: timer.shortBreakDuration, longBreak: timer.longBreakDuration)
                showSettings = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(width: 350, height: 300)
    }
    
    // MARK: - 计算属性
    
    private var progress: Double {
        guard timer.totalSeconds > 0 else { return 0 }
        return Double(timer.totalSeconds - timer.remainingSeconds) / Double(timer.totalSeconds)
    }
    
    private var timerColor: Color {
        switch timer.currentPhase {
        case .work: return .red
        case .shortBreak: return .green
        case .longBreak: return .blue
        }
    }
    
    private var timeString: String {
        let minutes = timer.remainingSeconds / 60
        let seconds = timer.remainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    private func dueDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天 HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "明天 HH:mm"
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }
}

// MARK: - 待办选择器

struct TodoPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let todos: [TodoItem]
    let onSelect: (TodoItem) -> Void
    @State private var searchText = ""
    
    private var filtered: [TodoItem] {
        if searchText.isEmpty { return todos }
        return todos.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择待办")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding()
            
            Divider()
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索待办...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding()
            
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("没有可用的待办")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filtered) { todoEntry in
                            TodoPickerRow(todo: todoEntry, onSelect: onSelect)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 500, height: 500)
    }
}

// MARK: - 行视图组件

struct TodoPickerRow: View {
    let todo: TodoItem
    let onSelect: (TodoItem) -> Void
    
    private var dueDateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: todo.isPinned ? "pin.fill" : "circle")
                .foregroundColor(todo.isPinned ? .orange : .secondary)
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    Text(todo.category)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    if let dueDate = todo.dueDate {
                        Text(dueDateFormatter.string(from: dueDate))
                            .font(.caption2)
                            .foregroundColor(todo.isOverdue ? .red : .secondary)
                    }
                }
            }
            
            Spacer()
            
            Image(systemName: "play.circle.fill")
                .foregroundColor(.accentColor)
                .font(.title3)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(todo)
        }
    }
}

struct LinkedTodoRow: View {
    let todoItem: TodoItem
    let onStart: () -> Void
    let dueDateText: (Date) -> String
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: todoItem.isPinned ? "pin.fill" : (todoItem.priority == .urgent ? "exclamationmark.circle.fill" : "circle"))
                .foregroundColor(todoItem.priority == .urgent ? .red : (todoItem.isPinned ? .orange : .secondary))
                .font(.caption)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(todoItem.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                
                if let dueDate = todoItem.dueDate {
                    Text(dueDateText(dueDate))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button(action: onStart) {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("为此待办启动番茄钟")
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
    }
}
