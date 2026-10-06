import SwiftUI

/// iOS 考试倒计时。
///
/// 数据由 `AppState_iOS.examCountdowns` 持有并自动持久化到
/// `StorageService`（无需额外服务），本视图负责增删改与展示。
struct ExamCountdownView_iOS: View {
    @EnvironmentObject var appState: AppState_iOS
    @Environment(\.appTheme) private var appTheme

    @State private var showsEditor = false
    @State private var editingExam: ExamCountdown?
    @State private var showsArchived = false

    private var active: [ExamCountdown] {
        appState.examCountdowns
            .filter { !$0.isArchived && !$0.isExpired }
            .sorted { $0.examDate < $1.examDate }
    }

    private var archived: [ExamCountdown] {
        appState.examCountdowns
            .filter { $0.isArchived || $0.isExpired }
            .sorted { $0.examDate > $1.examDate }
    }

    var body: some View {
        List {
            if active.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有考试安排", systemImage: "calendar.badge.exclamationmark")
                    } description: {
                        Text("添加考试日期，App 会在首页显示倒计时。")
                    }
                }
            } else {
                Section("进行中") {
                    ForEach(active) { exam in
                        ExamRow_iOS(exam: exam) {
                            editingExam = exam
                            showsEditor = true
                        } onArchive: {
                            archive(exam)
                        } onDelete: {
                            remove(exam)
                        }
                    }
                }
            }

            if showsArchived || !archived.isEmpty {
                Section {
                    if showsArchived {
                        ForEach(archived) { exam in
                            ExamRow_iOS(exam: exam) {
                                editingExam = exam
                                showsEditor = true
                            } onArchive: {
                                archive(exam)
                            } onDelete: {
                                remove(exam)
                            }
                        }
                    } else {
                        Button("显示已归档（\(archived.count)）") { showsArchived = true }
                    }
                } header: {
                    Text("历史")
                }
            }
        }
        .navigationTitle("考试倒计时")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editingExam = nil
                    showsEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showsEditor) {
            ExamCountdownEditor_iOS(existing: editingExam) { exam in
                if let index = appState.examCountdowns.firstIndex(where: { $0.id == exam.id }) {
                    appState.examCountdowns[index] = exam
                } else {
                    appState.examCountdowns.append(exam)
                }
            }
        }
    }

    private func archive(_ exam: ExamCountdown) {
        guard let index = appState.examCountdowns.firstIndex(where: { $0.id == exam.id }) else { return }
        appState.examCountdowns[index].isArchived.toggle()
    }

    private func remove(_ exam: ExamCountdown) {
        appState.examCountdowns.removeAll { $0.id == exam.id }
    }
}

private struct ExamRow_iOS: View {
    @Environment(\.appTheme) private var appTheme
    let exam: ExamCountdown
    let onEdit: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("\(max(0, exam.daysRemaining))")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(exam.isUrgent ? Color.red : appTheme.accent)
                Text("天")
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)
            }
            .frame(width: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text(exam.name)
                    .font(.headline)
                    .foregroundStyle(appTheme.primaryText)

                if !exam.subject.isEmpty {
                    Text(exam.subject)
                        .font(.caption)
                        .foregroundStyle(appTheme.secondaryText)
                }

                Text(exam.examDate, format: .dateTime.year().month().day().weekday())
                    .font(.caption2)
                    .foregroundStyle(appTheme.secondaryText)

                if exam.isExpired {
                    Text("已结束")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.gray)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(appTheme.secondaryText)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .swipeActions(edge: .trailing) {
            Button(action: onDelete) {
                Label("删除", systemImage: "trash")
            }
            .tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button(action: onArchive) {
                Label(exam.isArchived ? "取消归档" : "归档", systemImage: "archivebox")
            }
            .tint(.orange)
        }
    }
}

private struct ExamCountdownEditor_iOS: View {
    @Environment(\.dismiss) private var dismiss

    let existing: ExamCountdown?
    let onCommit: (ExamCountdown) -> Void

    @State private var name = ""
    @State private var subject = ""
    @State private var examDate = Date()
    @State private var notes = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("考试信息") {
                    TextField("名称", text: $name)
                    TextField("科目", text: $subject)
                    DatePicker("考试时间", selection: $examDate)
                }
                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .navigationTitle(existing == nil ? "新建考试" : "编辑考试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { commit() }.disabled(name.isEmpty)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        subject = existing.subject
        examDate = existing.examDate
        notes = existing.notes
    }

    private func commit() {
        var exam = existing ?? ExamCountdown(name: name, examDate: examDate, subject: subject)
        exam.name = name
        exam.subject = subject
        exam.examDate = examDate
        exam.notes = notes
        onCommit(exam)
        dismiss()
    }
}