import SwiftUI

struct ReviewPlanView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme
    @State private var showCreateSheet = false
    @State private var selectedPlan: ReviewPlan?

    var body: some View {
        NavigationStack {
            Group {
                if appState.reviewPlans.isEmpty {
                    emptyState
                } else {
                    plansList
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCreateSheet = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateReviewPlanView_iOS()
                    .environmentObject(appState)
            }
            .sheet(item: $selectedPlan) { plan in
                ReviewPlanDetailView_iOS(plan: plan)
                    .environmentObject(appState)
            }
            .refreshable { /* 刷新 */ }
        }
        .navigationTitle("复习计划")
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无复习计划", systemImage: "calendar.badge.clock")
        } description: {
            Text("创建复习计划，合理安排备考时间")
        } actions: {
            Button("新建计划") { showCreateSheet = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var plansList: some View {
        List {
            ForEach(appState.reviewPlans) { plan in
                ReviewPlanRow_iOS(plan: plan)
                    .onTapGesture { selectedPlan = plan }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            appState.reviewPlans.removeAll { $0.id == plan.id }
                            appState.storageService.saveReviewPlans(appState.reviewPlans)
                        } label: { Label("删除", systemImage: "trash") }

                        Button { /* 写入日历 */ } label: { Label("写入日历", systemImage: "calendar.badge.plus") }
                            .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct ReviewPlanRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let plan: ReviewPlan

    // `ReviewPlan` 以「天」为单位组织（`dailyPlans`），每天下面是若干
    // `ReviewTask`；进度因此按「已完成任务 / 全部任务」计算。
    private var allTasks: [ReviewTask] { plan.dailyPlans.flatMap(\.tasks) }
    var completedCount: Int { allTasks.count { $0.isCompleted } }
    var totalCount: Int { allTasks.count }
    var progress: Double { totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0 }

    /// 最近一个未完成的任务（含它所在的日期）。
    private var nextPendingTask: (task: ReviewTask, date: Date)? {
        for day in plan.dailyPlans where day.date >= Calendar.current.startOfDay(for: Date()) {
            if let task = day.tasks.first(where: { !$0.isCompleted }) {
                return (task, day.date)
            }
        }
        return plan.dailyPlans
            .flatMap { day in day.tasks.filter { !$0.isCompleted }.map { ($0, day.date) } }
            .sorted { $0.1 < $1.1 }
            .first
            .map { (task: $0.0, date: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.subject)
                        .font(.headline)
                        .foregroundStyle(appTheme.primaryText)
                    Text("考试：\(plan.examDate, style: .date)")
                        .font(.subheadline)
                        .foregroundStyle(appTheme.secondaryText)
                }

                Spacer()

                // 进度环
                ZStack {
                    Circle()
                        .stroke(appTheme.border, lineWidth: 4)
                        .frame(width: 48, height: 48)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(appTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 48, height: 48)
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(appTheme.primaryText)
                }
            }

            // 进度条
            ProgressView(value: progress)
                .tint(appTheme.accent)
                .scaleEffect(y: 2)

            HStack {
                Label("\(completedCount) / \(totalCount) 完成", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(appTheme.secondaryText)
                Spacer()
                if let nextTask = nextPendingTask {
                    Label("下一项：\(nextTask.task.title)", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(appTheme.accent)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct CreateReviewPlanView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme

    @State private var subject = ""
    @State private var examDate = Date().addingTimeInterval(30 * 24 * 3600)
    @State private var topicsText = ""
    @State private var sessionsPerWeek = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("科目名称", text: $subject, prompt: Text("如：高等数学、英语、计算机网络"))
                    DatePicker("考试日期", selection: $examDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }

                Section("复习主题（每行一个）") {
                    TextEditor(text: $topicsText)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if topicsText.isEmpty {
                                Text("线性代数\n概率论\n微积分\n...")
                                    .foregroundStyle(appTheme.secondaryText.opacity(0.5))
                                    .padding(8)
                            }
                        }
                }

                Section("强度设置") {
                    Stepper("每周复习 \(sessionsPerWeek) 次", value: $sessionsPerWeek, in: 1...7)
                }

                Section {
                    Button {
                        createPlan()
                    } label: {
                        Text("生成复习计划")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(subject.isEmpty || topicsText.isEmpty)
                }
            }
            .navigationTitle("新建复习计划")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func createPlan() {
        let topics = topicsText.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !topics.isEmpty else { return }

        appState.createReviewPlan(examDate: examDate, subject: subject, topics: topics)
        dismiss()
    }
}

struct ReviewPlanDetailView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var appTheme
    let plan: ReviewPlan

    var body: some View {
        NavigationStack {
            List {
                Section("计划信息") {
                    HStack { Text("科目"); Spacer(); Text(plan.subject).foregroundStyle(appTheme.secondaryText) }
                    HStack { Text("考试日期"); Spacer(); Text(plan.examDate, style: .date).foregroundStyle(appTheme.secondaryText) }
                    HStack { Text("创建时间"); Spacer(); Text(plan.createdAt, format: .dateTime).foregroundStyle(appTheme.secondaryText) }
                }

                Section("复习安排") {
                    ForEach(plan.dailyPlans) { day in
                        DisclosureGroup {
                            ForEach(day.tasks) { task in
                                ReviewTaskRow_iOS(task: task, date: day.date) {
                                    toggle(task: task, in: day)
                                }
                            }
                        } label: {
                            HStack {
                                Text(day.date, style: .date)
                                Spacer()
                                Text("\(day.completedCount)/\(day.tasks.count)")
                                    .font(.caption)
                                    .foregroundStyle(appTheme.secondaryText)
                            }
                        }
                    }
                }

                Section {
                    Button("写入日历") {
                        Task { await appState.calendarService.createCalendarEvents(for: plan) }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    Button(role: .destructive) {
                        appState.reviewPlans.removeAll { $0.id == plan.id }
                        appState.storageService.saveReviewPlans(appState.reviewPlans)
                        dismiss()
                    } label: {
                        Text("删除计划").frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("计划详情")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }
    }

    /// 切换某条任务的完成状态。
    ///
    /// `ReviewTask` 是 `DailyPlan.tasks` 里的值类型，因此必须按下标定位后
    /// 整体替换；这里通过 ID 查找，避免依赖数组下标在前一次编辑后失效。
    private func toggle(task: ReviewTask, in day: DailyPlan) {
        guard let planIndex = appState.reviewPlans.firstIndex(where: { $0.id == plan.id }),
              let dayIndex = appState.reviewPlans[planIndex].dailyPlans.firstIndex(where: { $0.id == day.id }),
              let taskIndex = appState.reviewPlans[planIndex].dailyPlans[dayIndex].tasks.firstIndex(where: { $0.id == task.id })
        else { return }

        appState.reviewPlans[planIndex].dailyPlans[dayIndex].tasks[taskIndex].isCompleted.toggle()
        appState.reviewPlans[planIndex].dailyPlans[dayIndex].tasks[taskIndex].completedAt =
            appState.reviewPlans[planIndex].dailyPlans[dayIndex].tasks[taskIndex].isCompleted ? Date() : nil
        appState.storageService.saveReviewPlans(appState.reviewPlans)
        appState.hapticFeedbackService.selection()
    }
}

/// 单条复习任务。
struct ReviewTaskRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let task: ReviewTask
    let date: Date
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isCompleted ? Color.green : appTheme.secondaryText)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline)
                        .foregroundStyle(task.isCompleted ? appTheme.secondaryText : appTheme.primaryText)
                        .strikethrough(task.isCompleted)

                    HStack(spacing: 6) {
                        Text("\(task.estimatedMinutes) 分钟")
                            .font(.caption)
                            .foregroundStyle(appTheme.secondaryText)
                        if task.isCompleted, let completedAt = task.completedAt {
                            Text("完成于 \(completedAt, style: .date)")
                                .font(.caption2)
                                .foregroundStyle(appTheme.secondaryText)
                        }
                    }
                }

                Spacer()

                if !task.isCompleted {
                    Text("待复习")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(appTheme.accent.opacity(0.15))
                        .foregroundStyle(appTheme.accent)
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}