import SwiftUI

struct ReviewPlanView: View {
    @EnvironmentObject var appState: AppState
    @State private var showCreatePlan = false
    @State private var selectedPlan: ReviewPlan?
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if appState.reviewPlans.isEmpty {
                emptyStateView
            } else {
                plansListView
            }
        }
        .sheet(isPresented: $showCreatePlan) {
            CreatePlanView()
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
            
            Button {
                showCreatePlan = true
            } label: {
                Label("新建计划", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
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
            
            Button {
                showCreatePlan = true
            } label: {
                Label("创建复习计划", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var plansListView: some View {
        List(appState.reviewPlans) { plan in
            Button {
                selectedPlan = plan
            } label: {
                PlanRowView(plan: plan)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }
}

struct PlanRowView: View {
    let plan: ReviewPlan
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(plan.subject)
                    .font(.headline)
                
                Spacer()
                
                Text(plan.daysUntilExam)
                    .font(.subheadline)
                    .foregroundColor(examDateColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(examDateColor.opacity(0.1))
                    .cornerRadius(8)
            }
            
            HStack(spacing: 16) {
                Label("\(plan.dailyPlans.count) 天", systemImage: "calendar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Label("\(plan.totalTasks) 个任务", systemImage: "checklist")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Label("\(plan.completedTasks) 已完成", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            
            ProgressView(value: plan.progress)
                .tint(.accentColor)
            
            HStack {
                ForEach(plan.topics.prefix(3), id: \.id) { topic in
                    Text(topic.name)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                }
                
                if plan.topics.count > 3 {
                    Text("+ \(plan.topics.count - 3)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    private var examDateColor: Color {
        let days = plan.totalDays
        if days < 0 {
            return .gray
        } else if days <= 3 {
            return .red
        } else if days <= 7 {
            return .orange
        } else {
            return .green
        }
    }
}

struct CreatePlanView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var subject = ""
    @State private var examDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @State private var topicsText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    subjectSection
                    examDateSection
                    topicsSection
                }
                .padding()
            }
            
            Divider()
            
            footerView
        }
        .frame(width: 500, height: 450)
    }
    
    private var headerView: some View {
        HStack {
            Text("创建复习计划")
                .font(.headline)
            Spacer()
        }
        .padding()
    }
    
    private var subjectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("考试科目", systemImage: "book")
                .font(.headline)
            
            TextField("例如：高等数学", text: $subject)
                .textFieldStyle(.roundedBorder)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var examDateSection: some View {
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
    }
    
    private var topicsSection: some View {
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
                let topics = topicsText.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                
                Text("将创建 \(topics.count) 个复习要点")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var footerView: some View {
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
            .disabled(subject.isEmpty || topicsText.isEmpty)
        }
        .padding()
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
