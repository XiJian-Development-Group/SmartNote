import SwiftUI

struct HabitTrackerView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @State private var showCreateSheet = false
    @State private var selectedDate = Date()
    @State private var showCalendar = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 日期选择器
                DatePickerView(selectedDate: $selectedDate, showCalendar: $showCalendar)

                // 习惯列表
                if appState.habitService.habits.isEmpty {
                    emptyState
                } else {
                    habitsList
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateHabitView_iOS()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showCalendar) {
                CalendarPickerView(selectedDate: $selectedDate)
            }
        }
        .navigationTitle("习惯打卡")
    }

    private var habitsList: some View {
        List {
            ForEach(appState.habitService.habits) { habit in
                HabitRow_iOS(habit: habit, date: selectedDate)
                    .environmentObject(appState)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            appState.habitService.deleteHabit(id: habit.id)
                        } label: { Label("删除", systemImage: "trash") }

                        Button { /* 编辑 */ } label: { Label("编辑", systemImage: "pencil") }
                            .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无习惯", systemImage: "checkmark.square")
        } description: {
            Text("点击右上角 + 创建第一个习惯")
        } actions: {
            Button("新建习惯") { showCreateSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct DatePickerView: View {
    @Environment(\.appTheme) private var appTheme
    @Binding var selectedDate: Date
    @Binding var showCalendar: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { changeDate(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Button { showCalendar = true } label: {
                    VStack(spacing: 2) {
                        Text(selectedDate, format: .dateTime.weekday(.wide).month(.wide).day())
                            .font(.headline)
                        Text(selectedDate, format: .dateTime.year())
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                    }
                }
                Spacer()
                Button { changeDate(1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal)

            // 周视图
            HStack(spacing: 0) {
                ForEach(weekDays, id: \.self) { date in
                    DayCell(date: date, isSelected: Calendar.current.isDate(date, inSameDayAs: selectedDate), isToday: Calendar.current.isDateInToday(date))
                        .onTapGesture { selectedDate = date }
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 12)
        .background(appTheme.surface)
    }

    private var weekDays: [Date] {
        let calendar = Calendar.current
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? selectedDate
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: startOfWeek) }
    }

    private func changeDate(_ days: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }
}

struct DayCell: View {
    @Environment(\.appTheme) private var appTheme
    let date: Date
    let isSelected: Bool
    let isToday: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(date, format: .dateTime.weekday(.narrow))
                .font(.caption)
                .foregroundStyle(isSelected ? .white : (isToday ? appTheme.accent : appTheme.secondaryText))

            Text(date, format: .dateTime.day())
                .font(.subheadline.weight(isSelected || isToday ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : (isToday ? appTheme.accent : appTheme.primaryText))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            Group {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10).fill(appTheme.accent)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 10).stroke(appTheme.accent, lineWidth: 2)
                } else {
                    Color.clear
                }
            }
        )
    }
}

struct CalendarPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDate: Date

    var body: some View {
        NavigationStack {
            DatePicker("", selection: $selectedDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("选择日期")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }
    }
}

struct HabitRow_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    let habit: Habit
    let date: Date

    /// 打卡状态直接来自 `HabitService.habits` 里的权威数据，
    /// 不再维护一份本地 @State——否则界面会与已保存的记录脱节。
    private var isCompleted: Bool {
        HabitRow_iOS.isCheckedIn(habit, on: date)
    }

    /// 某天是否已打卡（按自然日比较，忽略具体时刻）。
    private static func isCheckedIn(_ habit: Habit, on date: Date) -> Bool {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: date)
        return habit.checkIns.contains { calendar.startOfDay(for: $0) == target }
    }

    var body: some View {
        HStack(spacing: 12) {
            // 打卡按钮
            Button {
                // `checkIn` 幂等：重复打卡不会写入第二条记录。
                let changed = appState.habitService.checkIn(habitId: habit.id, at: date)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {}
                HapticFeedbackService.shared.context(changed ? .taskComplete : .taskFail)
            } label: {
                ZStack {
                    Circle()
                        .stroke(isCompleted ? Color.green : appTheme.border, lineWidth: 2)
                        .frame(width: 44, height: 44)
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(habit.name)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)

                if let reminderTime = habit.reminderTime {
                    HStack(spacing: 4) {
                        Image(systemName: "bell.fill")
                            .font(.caption)
                        Text(reminderTime, style: .time)
                            .font(.caption)
                    }
                    .foregroundStyle(appTheme.secondaryText)
                }

                // 连续天数
                if habit.currentStreak > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("\(habit.currentStreak) 天连续")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // 频率标签
            Text(habit.frequency.displayName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(appTheme.surface)
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }
}

struct CreateHabitView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var name = ""
    @State private var frequency: HabitFrequency = .daily
    @State private var reminderEnabled = false
    @State private var reminderTime = Date()
    @State private var color: Color = .blue
    @State private var icon = "star.fill"

    let colors: [Color] = [.blue, .green, .orange, .red, .purple, .pink, .cyan, .yellow]
    let icons = ["star.fill", "heart.fill", "flame.fill", "leaf.fill", "drop.fill", "brain.head.profile", "figure.walk", "book.fill", "music.note", "moon.fill"]

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("习惯名称", text: $name)

                    Picker("频率", selection: $frequency) {
                        ForEach(HabitFrequency.allCases) { Text($0.displayName).tag($0) }
                    }

                    Toggle("提醒", isOn: $reminderEnabled)
                    if reminderEnabled {
                        DatePicker("提醒时间", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                }

                Section("外观") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(colors, id: \.self) { c in
                            Circle()
                                .fill(c)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if c == color {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { color = c }
                        }
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(icons, id: \.self) { i in
                            Image(systemName: i)
                                .font(.title2)
                                .frame(width: 44, height: 44)
                                .background(icon == i ? appTheme.accent.opacity(0.2) : appTheme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { icon = i }
                        }
                    }
                }
            }
            .navigationTitle("新建习惯")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        // 颜色与图标只是界面临时选择，Habit 模型不存储它们，
                        // 因此这里只写入共享模型真正拥有的字段。
                        let habit = Habit(
                            title: name,
                            intervalType: frequency.intervalType,
                            reminderTime: reminderEnabled ? reminderTime : nil
                        )
                        appState.habitService.addHabit(habit)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

extension Color {
    func toHex() -> String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r*255), Int(g*255), Int(b*255))
    }
}