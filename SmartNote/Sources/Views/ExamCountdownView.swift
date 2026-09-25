import SwiftUI

struct ExamCountdownView: View {
    @EnvironmentObject var appState: AppState
    @State private var showAddSheet = false
    @State private var newExamName = ""
    @State private var newExamDate = Date().addingTimeInterval(7 * 24 * 3600)
    @State private var newExamSubject = ""
    @State private var newExamNotes = ""
    
    var exams: [ExamCountdown] {
        appState.examCountdowns
            .filter { !$0.isArchived }
            .sorted { $0.examDate < $1.examDate }
    }
    
    var archivedExams: [ExamCountdown] {
        appState.examCountdowns
            .filter { $0.isArchived }
            .sorted { $0.examDate > $1.examDate }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            if exams.isEmpty {
                emptyStateView
            } else {
                examListView
            }
            
            if !archivedExams.isEmpty {
                archivedSection
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addExamSheet
        }
    }
    
    private var headerView: some View {
        HStack {
            Text("考试倒计时")
                .font(.title2)
                .fontWeight(.bold)
            
            Spacer()
            
            Button {
                showAddSheet = true
            } label: {
                Label("添加考试", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            
            Text("暂无考试安排")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Text("点击上方按钮添加考试日期")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
        }
    }
    
    private var examListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(exams) { exam in
                    ExamCountdownCard(exam: exam) {
                        archiveExam(exam)
                    } onDelete: {
                        deleteExam(exam)
                    }
                }
            }
            .padding()
        }
    }
    
    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            
            DisclosureGroup("已过期考试") {
                ForEach(archivedExams) { exam in
                    HStack {
                        Text(exam.name)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(exam.subject)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .padding(.horizontal)
        }
    }
    
    private var addExamSheet: some View {
        VStack(spacing: 20) {
            Text("添加考试")
                .font(.headline)
            
            Form {
                TextField("考试名称", text: $newExamName)
                
                DatePicker("考试日期", selection: $newExamDate, displayedComponents: [.date, .hourAndMinute])
                
                TextField("科目", text: $newExamSubject)
                
                TextField("备注（可选）", text: $newExamNotes)
            }
            .formStyle(.grouped)
            
            HStack {
                Button("取消") {
                    showAddSheet = false
                    resetForm()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("添加") {
                    addExam()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newExamName.isEmpty || newExamSubject.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }
    
    private func addExam() {
        let exam = ExamCountdown(
            name: newExamName,
            examDate: newExamDate,
            subject: newExamSubject,
            notes: newExamNotes
        )
        
        appState.examCountdowns.append(exam)
        // AppState.examCountdowns 的 didSet 负责落盘 examCountdowns.json
        
        showAddSheet = false
        resetForm()
    }
    
    private func archiveExam(_ exam: ExamCountdown) {
        if let index = appState.examCountdowns.firstIndex(where: { $0.id == exam.id }) {
            appState.examCountdowns[index].isArchived = true
        }
    }
    
    private func deleteExam(_ exam: ExamCountdown) {
        appState.examCountdowns.removeAll { $0.id == exam.id }
    }
    
    private func resetForm() {
        newExamName = ""
        newExamDate = Date().addingTimeInterval(7 * 24 * 3600)
        newExamSubject = ""
        newExamNotes = ""
    }
}

struct ExamCountdownCard: View {
    let exam: ExamCountdown
    let onArchive: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(exam.name)
                    .font(.headline)
                
                Text(exam.subject)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if !exam.notes.isEmpty {
                    Text(exam.notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            VStack(spacing: 4) {
                if exam.isExpired {
                    Text("已过期")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("\(exam.daysRemaining)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(exam.isUrgent ? .red : .accentColor)
                    
                    Text("天")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            VStack(spacing: 8) {
                Button {
                    onArchive()
                } label: {
                    Image(systemName: "archivebox")
                }
                .buttonStyle(.bordered)
                
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}
