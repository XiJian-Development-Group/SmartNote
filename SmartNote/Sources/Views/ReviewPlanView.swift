import SwiftUI

struct ReviewPlanView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCreatePlan = false
    @State private var selectedPlan: ReviewPlan?
    @State private var showPlanDetail = false
    @State private var showImportTopics = false
    
    var todayTasks: [ReviewTask] {
        let today = Calendar.current.startOfDay(for: Date())
        return appState.reviewPlans
            .flatMap { plan in
                plan.dailyPlans
                    .filter { Calendar.current.isDate($0.date, inSameDayAs: today) }
                    .flatMap { $0.tasks }
            }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if appState.reviewPlans.isEmpty {
                emptyStateView
            } else {
                HSplitView {
                    plansListView
                        .frame(minWidth: 280, maxWidth: 350)
                    
                    if let plan = selectedPlan {
                        PlanDetailView(plan: plan)
                    } else {
                        VStack {
                            if !todayTasks.isEmpty {
                                TodayTasksView(tasks: todayTasks)
                            } else {
                                VStack(spacing: 16) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 48))
                                        .foregroundColor(.secondary)
                                    Text("选择一个复习计划查看详情")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showCreatePlan) {
            CreatePlanView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showImportTopics) {
            ImportTopicsView()
                .environmentObject(appState)
        }
    }
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("复习计划")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("创建个性化复习计划，联动日历提醒")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if !todayTasks.isEmpty {
                Text("今日 \(todayTasks.count) 个任务")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            
            Menu {
                Button {
                    showCreatePlan = true
                } label: {
                    Label("新建计划", systemImage: "plus")
                }
                
                Button {
                    showImportTopics = true
                } label: {
                    Label("从资料导入知识点", systemImage: "doc.badge.plus")
                }
            } label: {
                Label("新建", systemImage: "plus")
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
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("暂无复习计划")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("点击「新建计划」创建个性化复习安排")
                .font(.body)
                .foregroundColor(.secondary)
            
            HStack(spacing: 12) {
                Button {
                    showCreatePlan = true
                } label: {
                    Label("创建计划", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    showImportTopics = true
                } label: {
                    Label("从资料导入", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var plansListView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("所有计划")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top)
            
            List(selection: $selectedPlan) {
                ForEach(appState.reviewPlans) { plan in
                    PlanRowView(plan: plan, isSelected: selectedPlan?.id == plan.id)
                        .tag(plan)
                        .contextMenu {
                            Button {
                                deletePlan(plan)
                            } label: {
                                Label("删除计划", systemImage: "trash")
                            }
                        }
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func deletePlan(_ plan: ReviewPlan) {
        appState.reviewPlans.removeAll { $0.id == plan.id }
        appState.storageService.saveReviewPlans(appState.reviewPlans)
        if selectedPlan?.id == plan.id {
            selectedPlan = nil
        }
    }
}

struct PlanRowView: View {
    let plan: ReviewPlan
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(plan.subject)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                Text(plan.daysUntilExam)
                    .font(.caption)
                    .foregroundColor(examDateColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(examDateColor.opacity(0.15))
                    .cornerRadius(6)
            }
            
            HStack(spacing: 12) {
                Label("\(plan.dailyPlans.count)天", systemImage: "calendar")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Label("\(plan.completedTasks)/\(plan.totalTasks)", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundColor(plan.completedTasks == plan.totalTasks ? .green : .secondary)
            }
            
            ProgressView(value: plan.progress)
                .tint(plan.completedTasks == plan.totalTasks ? .green : .accentColor)
        }
        .padding(.vertical, 6)
    }
    
    private var examDateColor: Color {
        let days = plan.totalDays
        if days < 0 { return .gray }
        else if days <= 3 { return .red }
        else if days <= 7 { return .orange }
        else { return .green }
    }
}

struct TodayTasksView: View {
    let tasks: [ReviewTask]
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sun.max.fill")
                    .foregroundColor(.yellow)
                Text("今日任务")
                    .font(.headline)
                Spacer()
                Text("\(tasks.filter { $0.isCompleted }.count)/\(tasks.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top)
            
            List(tasks) { task in
                TaskRowView(task: task) {
                    toggleTask(task)
                }
            }
            .listStyle(.inset)
        }
    }
    
    private func toggleTask(_ task: ReviewTask) {
        for (planIndex, plan) in appState.reviewPlans.enumerated() {
            for (dailyIndex, daily) in plan.dailyPlans.enumerated() {
                if let taskIndex = daily.tasks.firstIndex(where: { $0.id == task.id }) {
                    appState.reviewPlans[planIndex].dailyPlans[dailyIndex].tasks[taskIndex].isCompleted.toggle()
                    appState.storageService.saveReviewPlans(appState.reviewPlans)
                    return
                }
            }
        }
    }
}

struct TaskRowView: View {
    let task: ReviewTask
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(task.isCompleted ? .green : .secondary)
                    .font(.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.body)
                        .strikethrough(task.isCompleted)
                        .foregroundColor(task.isCompleted ? .secondary : .primary)
                    
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Text("\(task.estimatedMinutes)分钟")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct PlanDetailView: View {
    let plan: ReviewPlan
    @EnvironmentObject var appState: AppState
    @State private var selectedDay: DailyPlan?
    
    var body: some View {
        VStack(spacing: 0) {
            planHeaderView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progressSection
                    
                    if let day = selectedDay ?? plan.dailyPlans.first {
                        dailyTasksSection(day: day)
                    }
                }
                .padding()
            }
        }
    }
    
    private var planHeaderView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.subject)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Text(plan.daysUntilExam)
                    .font(.subheadline)
                    .foregroundColor(examDateColor)
            }
            
            HStack {
                Label("\(plan.totalDays) 天后考试", systemImage: "calendar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Label("\(plan.completedTasks)/\(plan.totalTasks) 任务完成", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(plan.completedTasks == plan.totalTasks ? .green : .secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var examDateColor: Color {
        let days = plan.totalDays
        if days < 0 { return .gray }
        else if days <= 3 { return .red }
        else if days <= 7 { return .orange }
        else { return .green }
    }
    
    /// 百分比统一四舍五入，并限制在 0...100；非有限值按 0% 处理。
    private func percentageText(for ratio: Double) -> String {
        guard ratio.isFinite else { return "0%" }
        let boundedRatio = min(max(ratio, 0), 1)
        let percentage = roundedPercentage(boundedRatio * 100)
        return "\(percentage)%"
    }
    
    private func roundedPercentage(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, 0), 100)
        return Int(clamped.rounded(.toNearestOrAwayFromZero))
    }
    
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("复习进度")
                .font(.headline)
            
            HStack {
                ProgressView(value: plan.progress)
                    .tint(plan.completedTasks == plan.totalTasks ? .green : .accentColor)
                
                Text("\(percentageText(for: plan.progress))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(plan.dailyPlans) { day in
                        DayButton(
                            day: day,
                            isSelected: selectedDay?.id == day.id
                        ) {
                            selectedDay = day
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func dailyTasksSection(day: DailyPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(formatDate(day.date))
                    .font(.headline)
                
                Spacer()
                
                Text("\(day.tasks.filter { $0.isCompleted }.count)/\(day.tasks.count) 完成")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ForEach(day.tasks) { task in
                TaskRowView(task: task) {
                    toggleTask(task)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            return "今天"
        } else if Calendar.current.isDateInTomorrow(date) {
            return "明天"
        } else {
            formatter.dateFormat = "MM月d日 EEEE"
            return formatter.string(from: date)
        }
    }
    
    private func toggleTask(_ task: ReviewTask) {
        for (planIndex, p) in appState.reviewPlans.enumerated() where p.id == plan.id {
            for (dailyIndex, daily) in p.dailyPlans.enumerated() {
                if let taskIndex = daily.tasks.firstIndex(where: { $0.id == task.id }) {
                    appState.reviewPlans[planIndex].dailyPlans[dailyIndex].tasks[taskIndex].isCompleted.toggle()
                    appState.storageService.saveReviewPlans(appState.reviewPlans)
                    return
                }
            }
        }
    }
}

struct DayButton: View {
    let day: DailyPlan
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(dayNumber)
                    .font(.caption)
                if day.isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                }
            }
            .frame(width: 36, height: 36)
            .background(isSelected ? Color.accentColor : (day.isCompleted ? Color.green.opacity(0.2) : Color.clear))
            .foregroundColor(isSelected ? .white : (day.isCompleted ? .green : .primary))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    private var dayNumber: String {
        let calendar = Calendar.current
        let dayOfMonth = calendar.component(.day, from: day.date)
        return "\(dayOfMonth)"
    }
}

struct ImportTopicsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedMaterial: StudyMaterial?
    @State private var importedTopics: [String] = []
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("从资料导入知识点")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            if let material = selectedMaterial, let keywords = material.keywords {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("从「\(material.name)」导入")
                            .font(.subheadline)
                        Spacer()
                        Button("取消选择") {
                            selectedMaterial = nil
                        }
                        .buttonStyle(.link)
                    }
                    
                    if !keywords.isEmpty {
                        Text("选择要导入的知识点：")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(keywords, id: \.self) { keyword in
                                    Toggle(isOn: Binding(
                                        get: { importedTopics.contains(keyword) },
                                        set: { newValue in
                                            if newValue {
                                                importedTopics.append(keyword)
                                            } else {
                                                importedTopics.removeAll { $0 == keyword }
                                            }
                                        }
                                    )) {
                                        Text(keyword)
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(height: 200)
                        
                        HStack {
                            Spacer()
                            Button("导入选中的知识点") {
                                importSelectedTopics()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(importedTopics.isEmpty)
                        }
                    } else {
                        Text("该资料暂无提取的知识点")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding()
            } else {
                VStack(spacing: 16) {
                    Text("选择一个资料来导入知识点")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    List(appState.materials.filter { !($0.keywords?.isEmpty ?? true) }) { material in
                        Button {
                            selectedMaterial = material
                        } label: {
                            HStack {
                                Image(systemName: material.type.icon)
                                VStack(alignment: .leading) {
                                    Text(material.name)
                                        .font(.body)
                                    Text("\(material.keywords?.count ?? 0) 个知识点")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedMaterial?.id == material.id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(height: 300)
                }
                .padding()
            }
        }
        .frame(width: 500, height: 450)
    }
    
    private func importSelectedTopics() {
        dismiss()
    }
}

struct CreatePlanView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var subject = ""
    @State private var examDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var topicsText = ""
    @State private var autoDistribute = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("创建复习计划")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("考试科目", systemImage: "book")
                            .font(.headline)
                        
                        TextField("例如：高等数学", text: $subject)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("考试日期", systemImage: "calendar")
                            .font(.headline)
                        
                        DatePicker(
                            "考试日期",
                            selection: $examDate,
                            in: Date()...,
                            displayedComponents: [.date]
                        )
                        .datePickerStyle(.field)
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("复习要点", systemImage: "list.bullet")
                            .font(.headline)
                        
                        Text("每行一个知识点（用逗号分隔）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $topicsText)
                            .font(.body)
                            .frame(height: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        
                        if !topicsText.isEmpty {
                            let topicCount = topicsText.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                                .count
                            
                            Text("共 \(topicCount) 个知识点")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Toggle("自动分配每日任务", isOn: $autoDistribute)
                                .font(.caption)
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                .padding()
            }
            
            Divider()
            
            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("创建计划") {
                    createPlan()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(subject.isEmpty || topicsText.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
    }
    
    private func createPlan() {
        let topics = topicsText.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        appState.createReviewPlan(
            examDate: examDate,
            subject: subject,
            topics: topics
        )
        
        dismiss()
    }
}
